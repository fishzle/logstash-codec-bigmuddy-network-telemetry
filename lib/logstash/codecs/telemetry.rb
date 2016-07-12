# encoding: utf-8
#
require "logstash/codecs/base"
require "logstash/namespace"
require 'json'
require "zlib"

##########**********************************
#
# IOS XR 6.0.0 wire format
#
# JSON Telemetry encoding
#
# ----------------------------------
#
#       +-----+-+-+-...++-+-+-...+-+-+-...++-+-+-...+
#       | Len |T|L|V...||T|L|V...|T|L|V...||T|L|V...|
#       +-----+-+-+-...++-+-+-...+-+-+-...++-+-+-...+
#
# Len - Length of encoded blocks (excluding length)
#
# T   - TSCodecTLVType
# L   - Length of block
# V   - Block (T == TS_CODEC_TLV_TYPE_COMPRESSOR_RESET => 0 length)
#
# ----------------------------------
TS_CODEC_HEADER_LENGTH_IN_BYTES = 4
#
# Payload is encoded as TLV, with two types
#
module TSCodecTLVType
  #
  # Type 1 carries signal to reset decompressor. No content is carried
  # in the compressor reset.
  #
  TS_CODEC_TLV_TYPE_COMPRESSOR_RESET = 1
  #
  # Type 2 carries compressed JSON
  #
  TS_CODEC_TLV_TYPE_JSON = 2
end

#
# IOS XR 6.1.0 wire format (version 2)
#
# JSON and GPB Telemetry encoding
#
# ----------------------------------
#
#       +-+-+-+-...-++-+-+-+-...-++-+-+-+-...+
#       |T|F|L|V... ||T|F|L|V... ||T|F|L|V...|
#       +-+-+-+-...-++-+-+-+-...-++-+-+-+-...+
#
# T   - 32 bits, type ( JSON == 2, GPB compact == 3, GPB kv == 4)
# F   - 32 bits, 0x0 No flags set – default behavior - nocompression
#		 0x1 indicates ZLIB compression, set when T == 2|3|4
# L   - 32 bits, Length of block excluding header
# V   - Data block
#
# ----------------------------------

TS_CODEC_HEADER_LENGTH_IN_BYTES_V2 = 12

module TSCodecTLVTypeV2
  #
  # Type 1 carries signal to reset decompressor. No content is carried
  # in the compressor reset.
  #
  TS_CODEC_TLV_TYPE_V2_JSON = 2
  TS_CODEC_TLV_TYPE_V2_GPB_COMPACT = 3
  TS_CODEC_TLV_TYPE_V2_GPB_KV = 4
end

#
# Outermost description of the messages in the stream
#
module TSCodecState
  TS_CODEC_PENDING_HEADER = 1
  TS_CODEC_PENDING_DATA = 2
end

#####*******************************************

def telemetry_gpb_camelise s
  s.split('_').collect {|w| w.capitalize}.join
end

def telemetry_gpb_extract_cisco_extensions_from_proto protofile
  #
  # Function takes care of returning the mapping between schema path
  # and corresponding class or module::class.
  #
  # We rely on the properties of the autogenerated .proto file.  We
  # expect to find at most one pertinent 'package' instruction in the
  # .proto file, and we expect one piece of metadata which talks about
  # paths and schema paths.
  #
  modulenames = nil
  classname = nil
  path = nil
  theclass = nil

  f = File.open(protofile, "r")
  f.each do |line|

    #
    # Extract module - this is important to protect against name space
    # pollution (e.g. where multiple sysdb bags point at the same bag)
    #
    m = line.match('package \s*(?<modulename>[\w\.]+)\s*;') 
    if m and m['modulename']
      modulenames = m['modulename'].split('.').map do |raw|
        #
        # We could camelise, but then RootOper becomes Rootoper which
        # is not what protouf compiler does.
        #
        telemetry_gpb_camelise raw
        #raw
      end
    end

    #
    # Extract bag name and path from metadata.
    #
    m = line.match('.*metadata.*\\\"bag\\\": \\\"(?<bag>[\d\w]*)\\\".*\\\"schema_path\\\": \\\"(?<path>[\d\w\.]*)\\\".*') 
    if m and m['bag'] and m['path']
      classname = telemetry_gpb_camelise m['bag']
      path = m['path']
    end

  end # End of line by line iteration on file.

  f.close

  if path and classname
    mod = Kernel
    if modulenames
      modulenames.each do |modulename|
        mod = mod.const_get(modulename)
      end
    end
    theclass = mod.const_get(classname)
  end

  if theclass
    return [path, [theclass, classname]]
  end
end

#
# To turn on debugging, modify LS_OPTS in /etc/default/logstash to
# LS_OPTS="--debug"
#
# To view debugs, look at the file pointed at by LS_LOG_FILE
# which defaults to /var/log/logstash/logstash.log
#
class LogStash::Codecs::Telemetry< LogStash::Codecs::Base
  config_name "telemetry"
  ##############json
  #
  # Pick transformation we choose to apply in codec. The choice will
  # depend on the output plugin and downstream consumer.
  #
  # flat: flattens the JSON tree into path (as in path from root to leaf),
  #       and type (leaf name), and value.
  #  raw: passes the JSON segments as received.
  #
  config :xform, :validate => ["flat", "raw"], :default => "flat"

  #
  # Table of regexps is used when flattening, to identify the point to
  # flatten to down the JSON tree.
  #
  config :xform_flat_keys, :validate => :hash, :default => {}

  #
  # When flattening, we use a delimeter in the flattened path.
  #
  config :xform_flat_delimeter, :validate => :string, :default => "~"
  #
  # Wire format version number.
  #
  # XR 6.0 streams to the default version 1
  # XR 6.1 streams and later, require wire_format 2.
  #
  #config :wire_format, :validate => :number, :default => 1

  ##############gpb
  #
  # 'protofiles' specified path for directory holding:
  #
  # .proto files as generated on router, and post-processed
  # .pb.rb generated ruby bindings for the same
  #
  # e.g. protofiles => "/data/proto"
  #
  # If you do not plan to make backward incompatible
  # changes to the .proto file, you can also simply use
  # the full version on this side safe in the knowledge
  # that it will be able to read any subset you wish to
  # generate.
  #
  # In order to generate the Ruby bindings you will need
  # to use a protocol compiler which supports Ruby
  # bindings for proto2 (e.g. ruby-protocol-buffer gem)
  #
  config :protofiles, :validate => :path, :default => "./"


  ############**********************************
  #
  # Change state to reflect whether we are waiting for length or data.
  #
  private
  def ts_codec_change_state(state, pending_bytes)

    @logger.debug? &&
      @logger.debug("state transition", :from_state => @codec_state,
                    :to_state => state, :wait_for => pending_bytes)

    @codec_state = state
    @pending_bytes = pending_bytes
  end

  private
  def ts_codec_extract_path_key_value(path_raw,path, data, filter_table, depth)
    #
    # yield path,type,value triples from "Data" hash
    #
    data.each do |branch,v|

      path_and_branch = path + @xform_flat_delimeter + branch
      new_filter_table = []
      yielded = false

      #
      # Let's see if operator configuration wishes to consider the
      # prefix path+branch as an atomic event. The rest of the branch
      # will contributed event content. Apply filters, and if we have
      # an exact match yield event:
      #
      # path=path+branch (matching filter),
      # type=<configured name assoc with filter>,
      # content (remaining branch, and possibly, extracted key)
      #
      # (If we have a prefix match as opposed to complete match, we
      # need to keep going down the JSON tree. Build table of
      # applicable subset of filters for next level down)
      #
      if not filter_table.nil?
        filter_table.each do |name_and_filter_hash|

          #
          # We avoid using shift and instead use depth index to
          # avoid cost of mutating and copying filters.  Yet another
          # argument to organise filters as tree.
          #
          filter = name_and_filter_hash[:filter]
          filter_regexp = filter[depth]
          if filter_regexp
            match = branch.match(filter_regexp)
            if match

              if (depth == 0)
                #
                # Looks like we're going to use this filter and we may
                # collect captured matches and carry them all the way
                # down. Discard any stale state at this point.
                #
                name_and_filter_hash[:captured_matches] = []
              end

              #
              # We have a complete match and can terminate here.
              #
              if not match.names.empty?
                #
                # If the key regexp captured any part of the path, we
                # track the captured named matches as an array of
                # pairs.
                #
                match.names.each do |fieldname|
                  name_and_filter_hash[:captured_matches] <<
                    [fieldname, match[fieldname]]
                end
              end # Captured fields in path

              if not filter[depth+1]

                #
                # We're out here on this branch. Collect all the captured
                # matches, and set them up as key, along with the subtree
                # beneath this point and yield
                #
                if name_and_filter_hash.empty?
                  value = v
                else
                  value = {
                    name_and_filter_hash[:name] => v,
                    "key" => Hash[name_and_filter_hash[:captured_matches]]
                  }
                end

                yield path_and_branch, name_and_filter_hash[:name], value
                #
                # Force move to next outer iteration - i.e. next key
                # in object at this level. Could use exception or
                # throw/catch.
                #
                yielded = true
                break

              else # We have a prefix match
                #
                # Filter matches at this level but there are more
                # level in the filter. Add reference to name and
                # filter hash in filter table for the next level.
                #
                new_filter_table << name_and_filter_hash
              end # full or prefix match

            end # match or no match of current level

          end # do we have a filter for this level
        end # filter iteration
      end # do we even have a filter table?

      if yielded
        next
      end

      if v.is_a? Hash

        #
        # Lets walk down into this object and see what it yields.
        #
        ts_codec_extract_path_key_value(path_raw, path_and_branch, v,
                                        new_filter_table, depth + 1) do
          |newp, newk, newv|
          yield newp, newk, newv
        end

      else # This is not a hash, and therefore will be yielded (note: arrays too)
        # 
        # in this case, we inherit the path and type from the raw data and do the conversion
        #
        path_found = path_raw
        branch_found = branch

        found = false

        # find the correspond filter
        filter_table.each do |name_filter|

          filter_path_raw = path_raw.split('.')
          filter_path = name_filter[:filter]

          #
          # match the sub_path_raw with sub_filter
          # 
          for index in 0..(filter_path_raw.size-1) do
            sub_path = filter_path_raw[index]
            sub_filter = filter_path[index]
            sub_filter_next = filter_path[index+1]

            if sub_filter
              # /^(?<InterfaceName>.*)$/ to_s (?-mix:^(?<InterfaceName>.*)$)
              # pass the regex element
              if sub_filter.to_s.include? ".*" or sub_filter.to_s.include? "\d"
                found = true
              else
                sub_match = sub_path.match(sub_filter)
                if sub_match.nil?
                  found = false
                else
                  found = true
                end
              end
            else
              found = false
            end

            if found
              next
            else
              break
            end

          end

          # make sure the length of filter and raw are equal
          if found && sub_filter_next.nil?
            path_found = path_raw.gsub('.',@xform_flat_delimeter)
            branch_found = name_filter[:name]
            break
          end
        end

        yield path_found, branch_found, v
      end
    end # branch, v iteration over hash passed down
  end # ts_codec_extract_path_key_value


  #
  # telemetry_kv.proto
  #
  #
  # message Telemetry {
  #   optional uint64   collection_id = 1;
  #   optional string   base_path = 2;	
  #   optional string   subscription_identifier = 3;
  #   optional string   model_version = 4;
  #   optional uint64   collection_start_time = 5;
  #   optional uint64   msg_timestamp = 6;
  #   repeated TelemetryField tables = 14;
  #   optional uint64   collection_end_time = 15;
  # }
  #
  # message TelemetryTable {
  #   optional uint64         timestamp = 1;
  #   optional string         name = 2;
  #   optional bool           augment_data = 3;
  #   oneof value_by_type {
  #     bytes          bytes_value = 4;
  #     string         string_value = 5;
  #     bool           bool_value = 6;
  #     uint32         uint32_value = 7;
  #     uint64         uint64_value = 8;
  #     sint32         sint32_value = 9;
  #     sint64         sint64_value = 10;  
  #     double         double_value = 11;
  #     float          float_value = 12;
  #   }
  #   repeated TelemetryTable tables = 15;
  # }
  #
  
  # 
  # recursif function to decode TelemetryTable message
  # and produce event
  #
  private
  def produce_event_from_gpbkv_stream(table,evs,time_inherit)

    ev = Hash.new

    if table[:timestamp]
      ev[:timest] = table[:timestamp]
    else
      ev[:timest] = time_inherit
    end

    datatypes = Array[:bytes_value,
                 :string_value,
                 :bool_value,
                 :uint32_value,
                 :uint64_value,
                 :sint32_value,
                 :sint64_value,
                 :double_value,
                 :float_value]

    datatypes.each do |datatype|
      if table.has_key?(datatype)
        name = table[:name].to_s
        if datatype == :bytes_value
          value = table[datatype].to_s
        else
          value = table[datatype]
        end
        ev[name] = value
      end
    end

    if table[:tables].length != 0
      sub_tables = table[:tables]
      evs_sub = Hash.new
      sub_tables.each do |sub_table|
        produce_event_from_gpbkv_stream(sub_table,evs_sub,ev[:timest])
      end
      ev[:content] = evs_sub
    end

    if evs.class == Hash
      evs.update(ev)
    else
      evs.push(ev)
    end
  end

  ############********************************
  
  public
  def register
    #
    # Initialise the state of the codec. Codec is always cloned from
    # this state.
    #
    ##############*********************
    @codec_state = TSCodecState::TS_CODEC_PENDING_HEADER
    @pending_bytes = TS_CODEC_HEADER_LENGTH_IN_BYTES
    @zstream = Zlib::Inflate.new
    @data_compressed = 0
    @wire_format= nil
    @type = nil
    #############*****************************

    @logger.info("Registering cisco telemetry stream codec")

    #########################json  
    #
    # Preprocess the regexps strings provided, and build them out into
    # an array of hashes of the form (name, filter).
    #
    # filter Each is an array of regexps for every level in a path
    # down the JSON tree. We could have requested a JSON tree in
    # configuration, but this will be easier to configure.
    #
    filter_atom_arrays = []
    @filter_table = []

    begin
      @xform_flat_keys.each do |keyname, keyfilter|

        filter_atoms = keyfilter.split(@xform_flat_delimeter)
        filter_regexps = filter_atoms.map do |atom|
          Regexp.new("^" + atom + "$")
        end

        @filter_table << {
          :name => keyname,
          :filter => filter_regexps,
          :captured_matches => []}
      end
    rescue
      raise(LogStash::ConfigurationError, "xform_flat_keys processing failed")
    end

    if @xform == "flat"
      @logger.info("xform_flat filter table",
                   :filter_table => @filter_table.to_s)
    end

    ################gpb
    #
    # Load ruby binding source files for .proto
    #
    Dir.glob(@protofiles + "/*.pb.rb") do |binding_sourcefile|
      dir_and_file = File.absolute_path binding_sourcefile
      @logger.info("Loading ruby source file",
                   :proto_binding_source => dir_and_file)
      begin
        load dir_and_file
      rescue Exception => e
        @logger.warn("Failed to load .proto Ruby binding source",
                     :proto_binding_source => dir_and_file,
                     :exception => e, :stacktrace => e.backtrace)
      end
    end

    #
    # Build a map of paths to gpb rb binding objects (and name)
    #
    # Sample outcome:
    #
    # @protofiles_map = {
    #  "RootOper.FIB.Node.Protocol.VRF.IPPrefixBrief" =>
    #      [FibShTblFib, "FibShTblFib"],
    #  "RootOper.InfraStatistics.Interface.Latest.GenericCounters" =>
    #      [IfstatsbagGeneric, "IfstatsbagGeneric"]
    #   ...
    # }
    #
    #
    @protofiles_map =
      Hash[Dir.glob(@protofiles + "/*.proto").map { |p|
             telemetry_gpb_extract_cisco_extensions_from_proto p
           }]
    @logger.info("Loading ruby path to class map",
                 :protofiles_map => @protofiles_map.to_s)
  end

  public
  def decode(data)

    connection_thread = Thread.current

    #######*****************************

    @logger.debug? &&
      @logger.debug("Transport passing data down",
                    :thread => connection_thread.to_s,
                    :length => data.length,
                    :prepending => @partial_data.nil? ? 0 : @partial_data.length,
                    :waiting_for => @pending_bytes)
    unless @partial_data.nil?
      data = @partial_data + data
      @partial_data = nil
    end

    while data.length >= @pending_bytes

      case @codec_state

      when TSCodecState::TS_CODEC_PENDING_HEADER

        #
        # Handle message header - just currently one field, length.
        #
        next_msg_length_in_bytes, data = data.unpack('Na*')

        if (next_msg_length_in_bytes > 4)
          @wire_format = 1
          #
          # Format prior to v1 was always COMPRESSED JSON
          #
          @data_compressed = 1
        else
          @wire_format = 2
          next_message_type = next_msg_length_in_bytes;
          @data_compressed, next_msg_length_in_bytes, data =
            data.unpack('NNa*')
          @type = next_message_type
        end
        ts_codec_change_state(TSCodecState::TS_CODEC_PENDING_DATA,
                            next_msg_length_in_bytes)

      when TSCodecState::TS_CODEC_PENDING_DATA

        msg, data = data.unpack("a#{@pending_bytes}a*")

        if (@wire_format == 2)
          l = @pending_bytes
          ts_codec_change_state(TSCodecState::TS_CODEC_PENDING_HEADER,
                                TS_CODEC_HEADER_LENGTH_IN_BYTES_V2)
        else
          @type, l, msg = msg.unpack('NNa*')
          ts_codec_change_state(TSCodecState::TS_CODEC_PENDING_HEADER,
                                TS_CODEC_HEADER_LENGTH_IN_BYTES)
        end

        case @type

        when TSCodecTLVType::TS_CODEC_TLV_TYPE_COMPRESSOR_RESET
          @zstream = Zlib::Inflate.new
          @logger.debug? &&
            @logger.debug("Yielding COMPRESSOR RESET  decompressor",
                          :decompressor => @zstream)

        when TSCodecTLVType::TS_CODEC_TLV_TYPE_JSON  #(or TSCodecTLVTypeV2::TS_CODEC_TLV_TYPE_V2_JSON)
            v, msg = msg.unpack("a#{l}a*")

            if @data_compressed == 1
              decompressed_unit = @zstream.inflate(v)
              @logger.debug? &&
              @logger.debug("Parsed message", :zmsgtype => t, :zmsglength => l,
                            :msglength => decompressed_unit.length,
                            :decompressor => @zstream)
            else
              decompressed_unit = v
            end

            begin
              parsed_unit = JSON.parse(decompressed_unit)
            rescue JSON::ParserError => e
              @logger.info("JSON parse error: add text message", :exception => e,
                           :data => decompressed_unit)
              yield LogStash::Event.new("unparsed_message" => decompressed_unit)
            end

            case @xform
            when "raw"
              @logger.debug? &&
                @logger.debug("Yielding raw event", :event => parsed_unit)
              yield LogStash::Event.new(parsed_unit)

            when "flat"
              #
              # Flatten JSON to path+type (key), value
              #
              ts_codec_extract_path_key_value(parsed_unit["Path"],"DATA",
                                              parsed_unit["Data"],
                                              @filter_table, 0) do
                |path,type,content|

                event = {"path" => path,
                  "type" => type,
                  "content" => content,
                  "identifier" => parsed_unit['Identifier'],
                  "policy_name" => parsed_unit['Policy'],
                  "version" => parsed_unit['Version'],
                  "end_time" => parsed_unit['End Time']}

                if event["end_time"].nil?
                  #
                  # Pertinent IOS-XR 6.0.1 content
                  #
                  event["end_time"] = parsed_unit["CollectionEndTime"]
                  event["start_time"] = parsed_unit["CollectionStartTime"]
                  event["collection_id"] = parsed_unit["CollectionID"]
                end

                @logger.debug? &&
                  @logger.debug("Yielding flat event", :event => event)
                yield LogStash::Event.new(event)
              end

            else
              @logger.error("Unsupported xform", :xform => xform)
            end

        when TSCodecTLVTypeV2::TS_CODEC_TLV_TYPE_V2_GPB_COMPACT
          #####decode_compact(msg)
          if @protofiles_map.length != 0
            begin
              v, msg = msg.unpack("a#{l}a*")

              if @data_compressed == 1
                decompressed_unit = @zstream.inflate(v)
                @logger.debug? &&
                @logger.debug("Parsed message", :zmsgtype => t, :zmsglength => l,
                              :msglength => decompressed_unit.length,
                              :decompressor => @zstream)
              else
                decompressed_unit = v
              end

              msg_gpb = TelemetryHeader.new

              begin
                msg_out = msg_gpb.parse(decompressed_unit).to_hash
                tables = msg_out.delete(:tables)
                tables.each do |table|

                  @logger.debug? &&
                    @logger.debug("Message policy paths",
                                  :identifier => msg_out[:identifier],
                                  :policy_name => msg_out[:policy_name],
                                  :end_time => msg_out[:end_time],
                                  :policy_path => table[:policy_path])

                  #
                  # Map row to appropriate sub-message type and decode.
                  #
                  if @protofiles_map.has_key? table[:policy_path]
                    row_decoder_name = @protofiles_map[table[:policy_path]]
                    begin

                      row_decoder_class = row_decoder_name[0]
                      rows = table[:row]
                      rows.each do |row|

                        @logger.debug? &&
                          @logger.debug("Raw row", :row_raw => row.to_s,
                                        :row_decoder_name => row_decoder_name,
                                        :row_decoder_class => row_decoder_class.to_s)

                        #
                        # Perhaps just clear the object as opposed to allocate
                        # it for every iteration.
                        #
                        row_decoder = row_decoder_class.new
                        row_out = row_decoder.parse(row).to_hash
                        @logger.debug? &&
                          @logger.debug("Decoded row",
                                        :row_out => row_out.to_s)

                        #
                        # Merge header and row, stringify keys, and yield.
                        #
                        # Stringify operation copes with nested hashes too.
                        # .stringify in rails is what I am looking for, but this
                        # is not rails.
                        #
                        ev = msg_out.clone
                        ev[:end_time] = msg_out[:end_time]
                        ev[:content] = row_out
                        ev[:type] = row_decoder_name[1]
                        ev[:path] = table[:policy_path]
                        yield LogStash::Event.new(JSON.parse(ev.to_json))

                      end # End of iteration over rows

                    rescue Exception => e
                      @logger.warn("Failed to decode telemetry row",
                                   :policy_path => table[:policy_path],
                                   :decoder => row_decoder_name,
                                   :exception => e, :stacktrace => e.backtrace)
                    end # End of exception handling of row decode

                    @logger.debug? && @logger.debug("Iteration end")

                  else # No decoder is available

                    @logger.debug? &&
                      @logger.debug("No decoder available",
                                    :policy_path => table[:policy_path])

                  end # End of cases where a decoder is available, or not

                end # End of iteration over each table

              rescue Exception => e
                @logger.warn("Failed to decode telemetry header",
                             :data => decompressed_unit,
                             :exception => e, :stacktrace => e.backtrace)
              end
            end
          else
            @logger.warn("No setup to decode gpb, received gpb content is dropped ")
          end

        when TSCodecTLVTypeV2::TS_CODEC_TLV_TYPE_V2_GPB_KV
          #####!!!!decode_kv(msg)
          if @protofiles_map.length != 0
            begin
              v, msg = msg.unpack("a#{l}a*")

              if @data_compressed == 1
                decompressed_unit = @zstream.inflate(v)
                @logger.debug? &&
                @logger.debug("Parsed message", :zmsgtype => t, :zmsglength => l,
                              :msglength => decompressed_unit.length,
                              :decompressor => @zstream)
              else
                decompressed_unit = v
              end

              msg_gpb = Telemetry.new
              evs = Array.new

              begin
                msg_out = msg_gpb.parse(decompressed_unit).to_hash
                tables = msg_out.delete(:tables)
                tables.each do |table|

                  @logger.debug? &&
                    @logger.debug("Message policy paths",
                                  :collection_id => msg_out[:collection_id],
                                  :base_path => msg_out[:base_path],
                                  :msg_timestamp => msg_out[:msg_timestamp])

                  produce_event_from_gpbkv_stream(table,evs,msg_out[:msg_timestamp])
                end # End of iteration over each table

                evs.each do |ev|
                  ev.update(msg_out)
                  yield LogStash::Event.new(JSON.parse(ev.to_json))
                end

              rescue Exception => e
                @logger.warn("Failed to decode telemetry kv",
                             :data => decompressed_unit,
                             :exception => e, :stacktrace => e.backtrace)
              end
            end
          else
            @logger.warn("No setup to decode gpb_kv, received gpb_kv content is dropped ")
          end
         
        else
          # default case, something's gone awry
          @logger.error("Resetting connection on unknown type",
                         :type => @type)
          raise 'Unexpected message type in TLV:. Reset connection'
        end
      
      end
    end

    unless data.nil? or data.length == 0
      @partial_data = data
      @logger.debug? &&
        @logger.debug("Stashing data which has not been consumed "\
                      "until transport hands us the rest",
                      :msglength => @partial_data.length,
                      :waiting_for => @pending_bytes)
    else
      @partial_data = nil
    end

    ######*******************************
  end # def decode

  public
  def encode(event)
    # do nothing on encode for now
    @logger.info("cisco telemetry: no encode facility")
  end # def encode

end # class LogStash::Codecs::TelemetryStream

