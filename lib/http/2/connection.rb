module HTTP2
  # Default connection and stream flow control window (64KB).
  DEFAULT_FLOW_WINDOW = 65_535

  # Default header table size
  DEFAULT_HEADER_SIZE = 4096

  # Default stream_limit
  DEFAULT_MAX_CONCURRENT_STREAMS = 100

  # Default values for SETTINGS frame, as defined by the spec.
  SPEC_DEFAULT_CONNECTION_SETTINGS = {
    settings_header_table_size:       4096,
    settings_enable_push:             1,                     # enabled for servers
    settings_max_concurrent_streams:  Framer::MAX_STREAM_ID, # unlimited
    settings_initial_window_size:     65_535,
    settings_max_frame_size:          16_384,
    settings_max_header_list_size:    2**31 - 1,             # unlimited
  }.freeze

  DEFAULT_CONNECTION_SETTINGS = {
    settings_header_table_size:       4096,
    settings_enable_push:             1,     # enabled for servers
    settings_max_concurrent_streams:  100,
    settings_initial_window_size:     65_535, #
    settings_max_frame_size:          16_384,
    settings_max_header_list_size:    2**31 - 1,             # unlimited
  }.freeze

  # Default stream priority (lower values are higher priority).
  DEFAULT_WEIGHT    = 16

  # Default connection "fast-fail" preamble string as defined by the spec.
  CONNECTION_PREFACE_MAGIC = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".freeze

  # Connection encapsulates all of the connection, stream, flow-control,
  # error management, and other processing logic required for a well-behaved
  # HTTP 2.0 endpoint.
  #
  # Note that this class should not be used directly. Instead, you want to
  # use either Client or Server class to drive the HTTP 2.0 exchange.
  class Connection
    include FlowBuffer
    include Emitter
    include Error

    # Connection state (:new, :closed).
    attr_reader :state

    # Last connection error if connection is aborted.
    attr_reader :error

    # Size of current connection flow control window (by default, set to
    # infinity, but is automatically updated on receipt of peer settings).
    attr_reader :local_window
    attr_reader :remote_window
    alias_method :window, :local_window

    # Current settings value for local and peer
    attr_reader :local_settings
    attr_reader :remote_settings

    # Pending settings value
    #  Sent but not ack'ed settings
    attr_reader :pending_settings

    # Number of active streams between client and server (reserved streams
    # are not counted towards the stream limit).
    attr_reader :active_stream_count

    # Initializes new connection object.
    #
    def initialize(**settings)
      @local_settings  = DEFAULT_CONNECTION_SETTINGS.merge(settings)
      @remote_settings = SPEC_DEFAULT_CONNECTION_SETTINGS.dup

      @compressor   = Header::Compressor.new(settings)
      @decompressor = Header::Decompressor.new(settings)

      @active_stream_count = 0
      @streams = {}
      @pending_settings = []

      @framer = Framer.new

      @local_window_limit = @local_settings[:settings_initial_window_size]
      @local_window = @local_window_limit
      @remote_window_limit = @remote_settings[:settings_initial_window_size]
      @remote_window = @remote_window_limit

      @recv_buffer = Buffer.new
      @send_buffer = []
      @continuation = []
      @error = nil
    end

    # Allocates new stream for current connection.
    #
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def new_stream(**args)
      fail ConnectionClosed if @state == :closed
      fail StreamLimitExceeded if @active_stream_count >= @remote_settings[:settings_max_concurrent_streams]

      stream = activate_stream(id: @stream_id, **args)
      @stream_id += 2

      stream
    end

    # Sends PING frame to the peer.
    #
    # @param payload [String] optional payload must be 8 bytes long
    # @param blk [Proc] callback to execute when PONG is received
    def ping(payload, &blk)
      send(type: :ping, stream: 0, payload: payload)
      once(:ack, &blk) if blk
    end

    # Sends a GOAWAY frame indicating that the peer should stop creating
    # new streams for current connection.
    #
    # Endpoints MAY append opaque data to the payload of any GOAWAY frame.
    # Additional debug data is intended for diagnostic purposes only and
    # carries no semantic value. Debug data MUST NOT be persistently stored,
    # since it could contain sensitive information.
    #
    # @param error [Symbol]
    # @param payload [String]
    def goaway(error = :no_error, payload = nil)
      last_stream = if (max = @streams.max)
        max.first
      else
        0
      end

      send(type: :goaway, last_stream: last_stream,
           error: error, payload: payload)
      @state = :closed
    end

    # Sends a connection SETTINGS frame to the peer.
    # The values are reflected when the corresponding ACK is received.
    #
    # @param settings [Array or Hash]
    def settings(payload)
      payload = payload.to_a
      connection_error if validate_settings(@local_role, payload)
      @pending_settings << payload
      send(type: :settings, stream: 0, payload: payload)
      @pending_settings << payload
    end

    # Decodes incoming bytes into HTTP 2.0 frames and routes them to
    # appropriate receivers: connection frames are handled directly, and
    # stream frames are passed to appropriate stream objects.
    #
    # @param data [String] Binary encoded string
    def receive(data)
      @recv_buffer << data

      # Upon establishment of a TCP connection and determination that
      # HTTP/2.0 will be used by both peers, each endpoint MUST send a
      # connection header as a final confirmation and to establish the
      # initial settings for the HTTP/2.0 connection.
      #
      # Client connection header is 24 byte connection header followed by
      # SETTINGS frame. Server connection header is SETTINGS frame only.
      if @state == :waiting_magic
        if @recv_buffer.size < 24
          if !CONNECTION_PREFACE_MAGIC.start_with? @recv_buffer
            fail HandshakeError
          else
            return # maybe next time
          end
        elsif @recv_buffer.read(24) == CONNECTION_PREFACE_MAGIC
          # MAGIC is OK.  Send our settings
          @state = :waiting_connection_preface
          payload = @local_settings.reject { |k, v| v == SPEC_DEFAULT_CONNECTION_SETTINGS[k] }
          settings(payload)
        else
          fail HandshakeError
        end
      end

      while (frame = @framer.parse(@recv_buffer))
        emit(:frame_received, frame)

        # Header blocks MUST be transmitted as a contiguous sequence of frames
        # with no interleaved frames of any other type, or from any other stream.
        unless @continuation.empty?
          unless frame[:type] == :continuation && frame[:stream] == @continuation.first[:stream]
            connection_error
          end

          @continuation << frame
          return unless frame[:flags].include? :end_headers

          payload = @continuation.map { |f| f[:payload] }.join

          frame = @continuation.shift
          @continuation.clear

          frame.delete(:length)
          frame[:payload] = Buffer.new(payload)
          frame[:flags] << :end_headers
        end

        # SETTINGS frames always apply to a connection, never a single stream.
        # The stream identifier for a settings frame MUST be zero.  If an
        # endpoint receives a SETTINGS frame whose stream identifier field is
        # anything other than 0x0, the endpoint MUST respond with a connection
        # error (Section 5.4.1) of type PROTOCOL_ERROR.
        if connection_frame?(frame)
          connection_management(frame)
        else
          case frame[:type]
          when :headers
            # The last frame in a sequence of HEADERS/CONTINUATION
            # frames MUST have the END_HEADERS flag set.
            unless frame[:flags].include? :end_headers
              @continuation << frame
              return
            end

            # After sending a GOAWAY frame, the sender can discard frames
            # for new streams.  However, any frames that alter connection
            # state cannot be completely ignored.  For instance, HEADERS,
            # PUSH_PROMISE and CONTINUATION frames MUST be minimally
            # processed to ensure a consistent compression state
            decode_headers(frame)
            return if @state == :closed

            stream = @streams[frame[:stream]]
            if stream.nil?
              stream = activate_stream(
                id:         frame[:stream],
                weight:     frame[:weight] || DEFAULT_WEIGHT,
                dependency: frame[:dependency] || 0,
                exclusive:  frame[:exclusive] || false,
              )
              emit(:stream, stream)
            end

            stream << frame

          when :push_promise
            # The last frame in a sequence of PUSH_PROMISE/CONTINUATION
            # frames MUST have the END_HEADERS flag set
            unless frame[:flags].include? :end_headers
              @continuation << frame
              return
            end

            decode_headers(frame)
            return if @state == :closed

            # PUSH_PROMISE frames MUST be associated with an existing, peer-
            # initiated stream... A receiver MUST treat the receipt of a
            # PUSH_PROMISE on a stream that is neither "open" nor
            # "half-closed (local)" as a connection error (Section 5.4.1) of
            # type PROTOCOL_ERROR. Similarly, a receiver MUST treat the
            # receipt of a PUSH_PROMISE that promises an illegal stream
            # identifier (Section 5.1.1) (that is, an identifier for a stream
            # that is not currently in the "idle" state) as a connection error
            # (Section 5.4.1) of type PROTOCOL_ERROR, unless the receiver
            # recently sent a RST_STREAM frame to cancel the associated stream.
            parent = @streams[frame[:stream]]
            pid = frame[:promise_stream]

            connection_error(msg: 'missing parent ID') if parent.nil?

            unless parent.state == :open || parent.state == :half_closed_local
              # An endpoint might receive a PUSH_PROMISE frame after it sends
              # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
              # The RST_STREAM does not cancel any promised stream.  Therefore, if
              # promised streams are not desired, a RST_STREAM can be used to
              # close any of those streams.
              if parent.closed == :local_rst
                # We can either (a) 'resurrect' the parent, or (b) RST_STREAM
                # ... sticking with (b), might need to revisit later.
                send(type: :rst_stream, stream: pid, error: :refused_stream)
              else
                connection_error
              end
            end

            stream = activate_stream(id: pid, parent: parent)
            emit(:promise, stream)
            stream << frame
          else
            if (stream = @streams[frame[:stream]])
              stream << frame
            else
              # An endpoint that receives an unexpected stream identifier
              # MUST respond with a connection error of type PROTOCOL_ERROR.
              connection_error
            end
          end
        end
      end

    rescue => e
      raise if e.is_a?(Error::Error)
      connection_error
    end
    alias_method :<<, :receive

    private

    # Send an outgoing frame. DATA frames are subject to connection flow
    # control and may be split and / or buffered based on current window size.
    # All other frames are sent immediately.
    #
    # @note all frames are currently delivered in FIFO order.
    # @param frame [Hash]
    def send(frame)
      emit(:frame_sent, frame)
      if frame[:type] == :data
        send_data(frame, true)

      else
        # An endpoint can end a connection at any time. In particular, an
        # endpoint MAY choose to treat a stream error as a connection error.
        if frame[:type] == :rst_stream
          goaway(frame[:error]) if frame[:error] == :protocol_error
        else
          # HEADERS and PUSH_PROMISE may generate CONTINUATION
          frames = encode(frame)
          frames.each { |f| emit(:frame, f) }
        end
      end
    end

    # Applies HTTP 2.0 binary encoding to the frame.
    #
    # @param frame [Hash]
    # @return [Array of Buffer] encoded frame
    def encode(frame)
      frames = []

      if frame[:type] == :headers || frame[:type] == :push_promise
        frames = encode_headers(frame) # HEADERS and PUSH_PROMISE may create more than one frame
      else
        frames = [frame]               # otherwise one frame
      end

      frames.map { |f| @framer.generate(f) }
    end

    # Check if frame is a connection frame: SETTINGS, PING, GOAWAY, and any
    # frame addressed to stream ID = 0.
    #
    # @param frame [Hash]
    # @return [Boolean]
    def connection_frame?(frame)
      frame[:stream] == 0 ||
        frame[:type] == :settings ||
        frame[:type] == :ping ||
        frame[:type] == :goaway
    end

    # Process received connection frame (stream ID = 0).
    # - Handle SETTINGS updates
    # - Connection flow control (WINDOW_UPDATE)
    # - Emit PONG auto-reply to PING frames
    # - Mark connection as closed on GOAWAY
    #
    # @param frame [Hash]
    def connection_management(frame)
      case @state
      when :waiting_connection_preface
        # The first frame MUST be a SETTINGS frame at the start of a connection.
        @state = :connected
        connection_settings(frame)

      when :connected
        case frame[:type]
        when :settings
          connection_settings(frame)
        when :window_update
          @remote_window += frame[:increment]
          send_data(nil, true)
        when :ping
          if frame[:flags].include? :ack
            emit(:ack, frame[:payload])
          else
            send(type: :ping, stream: 0,
                 flags: [:ack], payload: frame[:payload])
          end
        when :goaway
          # Receivers of a GOAWAY frame MUST NOT open additional streams on
          # the connection, although a new connection can be established
          # for new streams.
          @state = :closed
          emit(:goaway, frame[:last_stream], frame[:error], frame[:payload])
        when :altsvc, :blocked
          emit(frame[:type], frame)
        else
          connection_error
        end
      else
        connection_error
      end
    end

    # Validate settings parameters.  See sepc Section 6.5.2.
    #
    # @param role [Symbol] The sender's role: :client or :server
    # @return nil if no error.  Exception object in case of any error.
    def validate_settings(role, settings)
      settings.each do |key, v|
        case key
        when :settings_header_table_size
          # Any value is valid
        when :settings_enable_push
          case role
          when :server
            # Section 8.2
            # Clients MUST reject any attempt to change the
            # SETTINGS_ENABLE_PUSH setting to a value other than 0 by treating the
            # message as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            return ProtocolError.new("invalid #{key} value") unless v == 0
          when :client
            # Any value other than 0 or 1 MUST be treated as a
            # connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            unless v == 0 || v == 1
              return ProtocolError.new("invalid #{key} value")
            end
          end
        when :settings_max_concurrent_streams
          # Any value is valid
        when :settings_initial_window_size
          # Values above the maximum flow control window size of 2^31-1 MUST
          # be treated as a connection error (Section 5.4.1) of type
          # FLOW_CONTROL_ERROR.
          unless v <= 0x7fffffff
            return FlowControlError.new("invalid #{key} value")
          end
        when :settings_max_frame_size
          # The initial value is 2^14 (16,384) octets.  The value advertised
          # by an endpoint MUST be between this initial value and the maximum
          # allowed frame size (2^24-1 or 16,777,215 octets), inclusive.
          # Values outside this range MUST be treated as a connection error
          # (Section 5.4.1) of type PROTOCOL_ERROR.
          unless 16_384 <= v && v <= 16_777_215
            return ProtocolError.new("invalid #{key} value")
          end
        when :settings_max_header_list_size
          # Any value is valid
          # else # ignore unknown settings
        end
      end
      nil
    end

    # Update connection settings based on parameters set by the peer.
    #
    # @param frame [Hash]
    def connection_settings(frame)
      connection_error unless frame[:type] == :settings && frame[:stream] == 0

      # Apply settings.
      #  side =
      #   local: previously sent and pended our settings should be effective
      #   remote: just received peer settings should immediately be effective
      settings, side = if frame[:flags].include?(:ack)
        # Process pending settings we have sent.
        [@pending_settings.shift, :local]
      else
        connection_error(check) if validate_settings(@remote_role, frame[:payload])
        [frame[:payload], :remote]
      end

      settings.each do |key, v|
        case side
        when :local
          @local_settings[key] = v
        when :remote
          @remote_settings[key] = v
        end

        case key
        when :settings_max_concurrent_streams
          # Do nothing.
          # The value controls at the next attempt of stream creation.

        when :settings_initial_window_size
          # A change to SETTINGS_INITIAL_WINDOW_SIZE could cause the available
          # space in a flow control window to become negative. A sender MUST
          # track the negative flow control window, and MUST NOT send new flow
          # controlled frames until it receives WINDOW_UPDATE frames that cause
          # the flow control window to become positive.
          case side
          when :local
            @local_window = @local_window - @local_window_limit + v
            @streams.each do |_id, stream|
              stream.emit(:local_window, stream.local_window - @local_window_limit + v)
            end

            @local_window_limit = v
          when :remote
            @remote_window = @remote_window - @remote_window_limit + v
            @streams.each do |_id, stream|
              # Event name is :window, not :remote_window
              stream.emit(:window, stream.remote_window - @remote_window_limit + v)
            end

            @remote_window_limit = v
          end

        when :settings_header_table_size
          # Setting header table size might cause some headers evicted
          case side
          when :local
            @decompressor.table_size = v
          when :remote
            @compressor.table_size = v
          end

        when :settings_enable_push
          # nothing to do

        when :settings_max_frame_size
          # nothing to do

          # else # ignore unknown settings
        end
      end

      case side
      when :local
        # Received a settings_ack.  Notify application layer.
        emit(:settings_ack, frame, @pending_settings.size)
      when :remote
        unless @state == :closed
          # Send ack to peer
          send(type: :settings, stream: 0, payload: [], flags: [:ack])
        end
      end
    end

    # Decode headers payload and update connection decompressor state.
    #
    # The receiver endpoint reassembles the header block by concatenating
    # the individual fragments, then decompresses the block to reconstruct
    # the header set - aka, header payloads are buffered until END_HEADERS,
    # or an END_PROMISE flag is seen.
    #
    # @param frame [Hash]
    def decode_headers(frame)
      if frame[:payload].is_a? String
        frame[:payload] = @decompressor.decode(frame[:payload])
      end

    rescue => e
      connection_error(:compression_error, msg: e.message)
    end

    # Encode headers payload and update connection compressor state.
    #
    # @param frame [Hash]
    # @return [Array of Frame]
    def encode_headers(frame)
      payload = frame[:payload]
      payload = @compressor.encode(payload) unless payload.is_a? String

      frames = []

      while payload.size > 0
        cont = frame.dup
        cont[:type] = :continuation
        cont[:flags] = []
        cont[:payload] = payload.slice!(0, @remote_settings[:settings_max_frame_size])
        frames << cont
      end
      if frames.empty?
        frames = [frame]
      else
        frames.first[:type]  = frame[:type]
        frames.first[:flags] = frame[:flags] - [:end_headers]
        frames.last[:flags] << :end_headers
      end

      frames

    rescue => e
      [connection_error(:compression_error, msg: e.message)]
    end

    # Activates new incoming or outgoing stream and registers appropriate
    # connection managemet callbacks.
    #
    # @param id [Integer]
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def activate_stream(id: nil, **args)
      connection_error(msg: 'Stream ID already exists') if @streams.key?(id)

      stream = Stream.new({ connection: self, id: id }.merge(args))

      # Streams that are in the "open" state, or either of the "half closed"
      # states count toward the maximum number of streams that an endpoint is
      # permitted to open.
      stream.once(:active) { @active_stream_count += 1 }
      stream.once(:close)  { @active_stream_count -= 1 }
      stream.on(:promise, &method(:promise)) if self.is_a? Server
      stream.on(:frame,   &method(:send))

      @streams[id] = stream
    end

    # Emit GOAWAY error indicating to peer that the connection is being
    # aborted, and once sent, raise a local exception.
    #
    # @param error [Symbol]
    # @option error [Symbol] :no_error
    # @option error [Symbol] :internal_error
    # @option error [Symbol] :flow_control_error
    # @option error [Symbol] :stream_closed
    # @option error [Symbol] :frame_too_large
    # @option error [Symbol] :compression_error
    # @param msg [String]
    def connection_error(error = :protocol_error, msg: nil)
      goaway(error) unless @state == :closed || @state == :new

      @state, @error = :closed, error
      klass = error.to_s.split('_').map(&:capitalize).join
      fail Error.const_get(klass), msg
    end
  end
end
