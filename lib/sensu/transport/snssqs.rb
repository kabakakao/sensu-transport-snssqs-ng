require 'sensu/transport/base'
require 'aws-sdk'
require 'statsd-ruby'
require 'json'
require 'retries'

module Sensu
  module Transport
    class SNSSQS < Sensu::Transport::Base
      attr_accessor :logger

      STRING_STR     = "String".freeze
      KEEPALIVES_STR = "keepalives".freeze
      PIPE_STR       = "pipe".freeze
      TYPE_STR       = "type".freeze

      def initialize
        @connected = false
        @subscribing = false

        # as of sensu 0.23.0 we need to call succeed when we have
        # successfully connected to SQS.
        #
        # we already have our own logic to maintain the connection to
        # SQS, so we can always say we're connected.
        #
        # See:
        # https://github.com/sensu/sensu/blob/cdc25b29169ef2dcd2e056416eab0e83dbe000bb/CHANGELOG.md#0230---2016-04-04
        succeed()
      end

      def connected?; @connected; end

      def connect(settings)
        @settings = settings
        @connected = true
        @results_callback = proc {}
        @keepalives_callback = proc {}
        # Sensu Windows install does not include a valid cert bundle for AWS
        Aws.use_bundled_cert! if Gem.win_platform?
        aws_client_settings = {region: @settings[:region]}
        unless @settings[:access_key_id].nil?
          aws_client_settings[:access_key_id] = @settings[:access_key_id]
          aws_client_settings[:secret_access_key] = @settings[:secret_access_key]
        end
        @sqs = Aws::SQS::Client.new aws_client_settings
        @sns = Aws::SNS::Client.new aws_client_settings

        # connect to statsd, if necessary
        @statsd = nil
        if !@settings[:statsd_addr].nil? and @settings[:statsd_addr] != ""
          pieces = @settings[:statsd_addr].split(':')
          @statsd = Statsd.new(pieces[0], pieces[1].to_i).tap { |sd|
            sd.namespace = @settings[:statsd_namespace]
          }
          @statsd_sample_rate = @settings[:statsd_sample_rate].to_f
        end
      end

      def statsd_incr(stat)
        @statsd.increment(stat, @statsd_sample_rate) unless @statsd.nil?
      end

      def statsd_time(stat)
        # always measure + run the block, but only if @statsd is set
        # do we actually report it.
        start = Time.now
        result = yield
        if !@statsd.nil?
          @statsd.timing(stat, ((Time.now - start) * 1000).round(5), @statsd_sample_rate)
        end
        result
      end

      # subscribe will begin "subscribing" to the consuming sqs queue.
      #
      # This method is intended for use by the Sensu server; fanout
      # subscriptions initiated by the Sensu client process are
      # treated as a no-op.
      #
      # What this really means is that we will start polling for
      # messages from the SQS queue, and, depending on the message
      # type, it will call the appropriate callback.
      #
      # This assumes that the SQS Queue is consuming "Raw" messages
      # from SNS.
      #
      # "subscribing" means that the "callback" parameter will be
      # called when there is a message for you to consume.
      #
      # "funnel" and "type" parameters are completely ignored.
      def subscribe(type, pipe, funnel = nil, options = {}, &callback)
        if type == :fanout
          self.logger.debug("skipping unsupported fanout subscription type=#{type}, pipe=#{pipe}, funnel=#{funnel}")
          return
        end

        self.logger.info("subscribing to type=#{type}, pipe=#{pipe}, funnel=#{funnel}")

        if pipe == KEEPALIVES_STR
          @keepalives_callback = callback
        else
          @results_callback = callback
        end

        unless @subscribing
          do_all_the_time {
            EM::Iterator.new(receive_messages, 10).each do |msg, iter|
              statsd_time("sqs.#{@settings[:consuming_sqs_queue_url]}.process_timing") {
                if msg.message_attributes[PIPE_STR].string_value == KEEPALIVES_STR
                  @keepalives_callback.call(msg, msg.body)
                else
                  @results_callback.call(msg, msg.body)
                end
              }
              iter.next
            end
          }
          @subscribing = true
        end
      end

      # acknowledge will delete the given message from the SQS queue.
      def acknowledge(info, &callback)
        EM.defer {
          @sqs.delete_message(
            queue_url: @settings[:consuming_sqs_queue_url],
            receipt_handle: info.receipt_handle,
          )
          statsd_incr("sqs.#{@settings[:consuming_sqs_queue_url]}.message.deleted")
          callback.call(info) if callback
        }
      end

      # publish publishes a message to the SNS topic.
      #
      # The type, pipe, and options are transformed into SNS message
      # attributes and included with the message.
      def publish(type, pipe, message, options = {}, &callback)
        attributes = {
          TYPE_STR => str_attr(type),
          PIPE_STR => str_attr(pipe)
        }
        options.each do |k, v|
          attributes[k.to_s] = str_attr(v.to_s)
        end
        EM.defer { send_message(message, attributes, &callback) }
      end

      private

      def str_attr(str)
        { :data_type => STRING_STR, :string_value => str }
      end

      def do_all_the_time(&blk)
        callback = proc {
          do_all_the_time(&blk)
        }
        EM.defer(blk, callback)
      end

      def send_message(msg, attributes, &callback)
        with_retries(:max_tries => 2, :base_sleep_seconds => 5.0) do
          resp = @sns.publish(
            target_arn: @settings[:publishing_sns_topic_arn],
            message: msg,
            message_attributes: attributes
          )
        end
        statsd_incr("sns.#{@settings[:publishing_sns_topic_arn]}.message.published")
        callback.call({ :response => resp }) if callback
      end

      PIPE_ARR = [PIPE_STR]

      # receive_messages returns an array of SQS messages
      # for the consuming queue
      def receive_messages
        begin
          resp = @sqs.receive_message(
            message_attribute_names: PIPE_ARR,
            queue_url: @settings[:consuming_sqs_queue_url],
            wait_time_seconds: @settings[:wait_time_seconds],
            max_number_of_messages: @settings[:max_number_of_messages],
          )
          resp.messages.select do |msg|
            # switching whether to transform the message based on the existance of message_attributes
            # if this is a raw SNS message, it exists in the root of the message and no conversion is needed
            # if it doesn't, it is an encapsulated messsage (meaning the SNS message is a stringified JSON in the body of the SQS message)
            begin
              self.logger.debug('[transport-snssqs] msg parse start')
              unless msg.key? 'message_attributes'
                # extracting original SNS message
                tmp_body = ::JSON.parse msg.body
                self.logger.debug('[transport-snssqs] msg parsed from JSON')
                # if there is no Message, this isn't a SNS message and something has gone terribly wrong
                unless tmp_body.key? 'Message'
                  self.logger.info('[transport-snssqs] msg body without SNS Message received')
                  next
                end
                # replacing the body with the SNS message (as it would be in a raw delivered SNS-SQS message)
                msg.body = tmp_body['Message']
                msg.message_attributes = {}
                # discarding messages without attributes, since this would lead to an exception in subscribe
                unless tmp_body.key? 'MessageAttributes'
                  self.logger.info('[transport-snssqs] msg body without message attributes received')
                  next
                end
                # parsing the message_attributes
                tmp_body['MessageAttributes'].each do |name, value|
                  msg.message_attributes[name] = Aws::SQS::Types::MessageAttributeValue.new
                  msg.message_attributes[name].string_value = value['Value']
                  msg.message_attributes[name].data_type = 'String'
                end
              end
              self.logger.debug('[transport-snssqs] msg parsed successfully')
              msg
            rescue ::JSON::JSONError => e
              self.logger.info(e)
            end
          end
        rescue Aws::SQS::Errors::ServiceError => e
          self.logger.info(e)
        end
      end
    end
  end
end
