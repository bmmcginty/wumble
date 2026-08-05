module Wumble
  # Small protobuf writer/reader for the handful of Mumble control messages we use.
  # Keeping this here avoids a generated-code dependency in the gateway.
  module Protobuf
    def self.varint(value : UInt64) : Bytes
      bytes = [] of UInt8
      loop do
        byte = (value & 0x7f).to_u8
        value >>= 7
        bytes << (value == 0 ? byte : byte | 0x80_u8)
        break if value == 0
      end
      Bytes.new(bytes.size) { |index| bytes[index] }
    end

    def self.field(number : Int, value : UInt64) : Bytes
      varint((number << 3).to_u64) + varint(value)
    end

    def self.bytes(number : Int, value : Bytes) : Bytes
      varint(((number << 3) | 2).to_u64) + varint(value.size.to_u64) + value
    end

    def self.string(number : Int, value : String) : Bytes
      bytes(number, value.to_slice)
    end

    def self.read_varint(data : Bytes, offset : Int32) : {UInt64, Int32}
      value = 0_u64
      shift = 0
      while offset < data.size
        byte = data[offset]
        offset += 1
        value |= ((byte & 0x7f).to_u64 << shift)
        return {value, offset} if byte & 0x80 == 0
        shift += 7
        raise "invalid protobuf varint" if shift > 63
      end
      raise "truncated protobuf varint"
    end

    def self.fields(data : Bytes, &block : Int32, Int32, Bytes ->)
      offset = 0
      while offset < data.size
        key, offset = read_varint(data, offset)
        number = (key >> 3).to_i
        wire = (key & 7).to_i
        case wire
        when 0
          value, offset = read_varint(data, offset)
          yield number, wire, varint(value)
        when 2
          length, offset = read_varint(data, offset)
          finish = offset + length.to_i
          raise "truncated protobuf field" if finish > data.size
          yield number, wire, data[offset...finish]
          offset = finish
        when 5
          finish = offset + 4
          raise "truncated protobuf field" if finish > data.size
          yield number, wire, data[offset...finish]
          offset = finish
        when 1
          finish = offset + 8
          raise "truncated protobuf field" if finish > data.size
          yield number, wire, data[offset...finish]
          offset = finish
        else
          raise "unsupported protobuf wire type #{wire}"
        end
      end
    end
  end
end
