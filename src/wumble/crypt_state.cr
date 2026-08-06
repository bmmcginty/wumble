require "openssl"

module Wumble
  # Mumble's AES-128-OCB packet format used by CryptSetup and UDPTunnel.
  # It is deliberately implemented here so encrypted Mumble UDP packets can be
  # passed through as Opus RTP without ever decoding or mixing their audio.
  class CryptState
    BLOCK_SIZE = 16

    @key : Bytes
    @decrypt_iv : Bytes
    @encrypt_iv : Bytes
    @history : StaticArray(UInt8, 256)

    def initialize(key : Bytes, client_nonce : Bytes, server_nonce : Bytes)
      raise "invalid Mumble crypt key" unless key.size == BLOCK_SIZE
      raise "invalid Mumble crypt nonce" unless client_nonce.size == BLOCK_SIZE && server_nonce.size == BLOCK_SIZE
      @key = key.dup
      @decrypt_iv = server_nonce.dup
      @encrypt_iv = client_nonce.dup
      @history = StaticArray(UInt8, 256).new(0_u8)
    end

    # Encrypts a native UDP payload using the outbound nonce established by
    # CryptSetup. The wire prefix carries the nonce's low byte and three bytes
    # of the OCB authentication tag.
    def encrypt(plaintext : Bytes) : Bytes
      increment_encrypt_iv
      ciphertext, tag = ocb_encrypt(plaintext, @encrypt_iv)
      packet = Bytes.new(ciphertext.size + 4)
      packet[0] = @encrypt_iv[0]
      packet[1] = tag[0]
      packet[2] = tag[1]
      packet[3] = tag[2]
      packet[4..].copy_from(ciphertext)
      packet
    end

    def decrypt(packet : Bytes) : Bytes?
      return nil if packet.size < 4
      saved_iv = @decrypt_iv.dup
      iv_byte = packet[0]
      restore = false

      if ((@decrypt_iv[0] &+ 1) == iv_byte)
        advance_iv if iv_byte < @decrypt_iv[0]
        @decrypt_iv[0] = iv_byte
      else
        diff = iv_byte.to_i - @decrypt_iv[0].to_i
        diff -= 256 if diff > 128
        diff += 256 if diff < -128
        if iv_byte < @decrypt_iv[0] && diff > -30 && diff < 0
          @decrypt_iv[0] = iv_byte
          restore = true
        elsif iv_byte > @decrypt_iv[0] && diff > -30 && diff < 0
          @decrypt_iv[0] = iv_byte
          retreat_iv
          restore = true
        elsif iv_byte > @decrypt_iv[0] && diff > 0
          @decrypt_iv[0] = iv_byte
        elsif iv_byte < @decrypt_iv[0] && diff > 0
          @decrypt_iv[0] = iv_byte
          advance_iv
        else
          return nil
        end
        if @history[@decrypt_iv[0]] == @decrypt_iv[1]
          @decrypt_iv = saved_iv
          return nil
        end
      end

      encrypted = packet[4..]
      plaintext, tag = ocb_decrypt(encrypted, @decrypt_iv)
      unless tag[0] == packet[1] && tag[1] == packet[2] && tag[2] == packet[3]
        @decrypt_iv = saved_iv
        return nil
      end
      @history[@decrypt_iv[0]] = @decrypt_iv[1]
      @decrypt_iv = saved_iv if restore
      plaintext
    end

    private def increment_encrypt_iv
      (0...BLOCK_SIZE).each do |index|
        @encrypt_iv[index] &+= 1
        break unless @encrypt_iv[index] == 0
      end
    end

    private def advance_iv
      (1...BLOCK_SIZE).each do |index|
        @decrypt_iv[index] &+= 1
        break unless @decrypt_iv[index] == 0
      end
    end

    private def retreat_iv
      (0...BLOCK_SIZE).each do |index|
        previous = @decrypt_iv[index]
        @decrypt_iv[index] &-= 1
        break unless previous == 0
      end
    end

    private def ocb_encrypt(plaintext : Bytes, nonce : Bytes) : {Bytes, Bytes}
      checksum = Bytes.new(BLOCK_SIZE, 0_u8)
      delta = aes_encrypt(nonce)
      ciphertext = Bytes.new(plaintext.size)
      remaining = plaintext.size
      source_offset = 0

      while remaining > BLOCK_SIZE
        shift2!(delta)
        block = plaintext[source_offset, BLOCK_SIZE]
        checksum = xor(checksum, block)
        ciphertext[source_offset, BLOCK_SIZE].copy_from(xor(delta, aes_encrypt(xor(delta, block))))
        source_offset += BLOCK_SIZE
        remaining -= BLOCK_SIZE
      end

      shift2!(delta)
      temporary = Bytes.new(BLOCK_SIZE, 0_u8)
      temporary[BLOCK_SIZE - 1] = (remaining * 8).to_u8
      pad = aes_encrypt(xor(temporary, delta))
      temporary = Bytes.new(BLOCK_SIZE, 0_u8)
      temporary[0, remaining].copy_from(plaintext[source_offset, remaining])
      ciphertext[source_offset, remaining].copy_from(xor(temporary, pad)[0, remaining])
      # OCB's final checksum includes the padded ciphertext XOR pad, matching
      # the value reconstructed by ocb_decrypt for the partial final block.
      temporary = Bytes.new(BLOCK_SIZE, 0_u8)
      temporary[0, remaining].copy_from(ciphertext[source_offset, remaining])
      checksum = xor(checksum, xor(temporary, pad))

      shift3!(delta)
      {ciphertext, aes_encrypt(xor(delta, checksum))}
    end

    private def ocb_decrypt(ciphertext : Bytes, nonce : Bytes) : {Bytes, Bytes}
      checksum = Bytes.new(BLOCK_SIZE, 0_u8)
      delta = aes_encrypt(nonce)
      plaintext = Bytes.new(ciphertext.size)
      remaining = ciphertext.size
      source_offset = 0

      while remaining > BLOCK_SIZE
        shift2!(delta)
        block = xor(delta, ciphertext[source_offset, BLOCK_SIZE])
        block = xor(delta, aes_decrypt(block))
        checksum = xor(checksum, block)
        plaintext[source_offset, BLOCK_SIZE].copy_from(block)
        source_offset += BLOCK_SIZE
        remaining -= BLOCK_SIZE
      end

      shift2!(delta)
      temporary = Bytes.new(BLOCK_SIZE, 0_u8)
      temporary[BLOCK_SIZE - 1] = (remaining * 8).to_u8
      temporary = xor(temporary, delta)
      pad = aes_encrypt(temporary)
      temporary = Bytes.new(BLOCK_SIZE, 0_u8)
      temporary[0, remaining].copy_from(ciphertext[source_offset, remaining])
      temporary = xor(temporary, pad)
      checksum = xor(checksum, temporary)
      plaintext[source_offset, remaining].copy_from(temporary[0, remaining])

      shift3!(delta)
      tag = aes_encrypt(xor(delta, checksum))
      {plaintext, tag}
    end

    private def aes_encrypt(block : Bytes) : Bytes
      cipher = OpenSSL::Cipher.new("AES-128-ECB")
      cipher.encrypt
      cipher.padding = false
      cipher.key = @key
      cipher.update(block)
    end

    private def aes_decrypt(block : Bytes) : Bytes
      cipher = OpenSSL::Cipher.new("AES-128-ECB")
      cipher.decrypt
      cipher.padding = false
      cipher.key = @key
      cipher.update(block)
    end

    private def xor(left : Bytes, right : Bytes) : Bytes
      Bytes.new(BLOCK_SIZE) { |index| left[index] ^ right[index] }
    end

    private def shift2!(block : Bytes)
      carry = block[0] >> 7
      (0...BLOCK_SIZE - 1).each { |index| block[index] = (block[index] << 1) | (block[index + 1] >> 7) }
      block[BLOCK_SIZE - 1] = (block[BLOCK_SIZE - 1] << 1) ^ (carry * 0x87)
    end

    private def shift3!(block : Bytes)
      carry = block[0] >> 7
      (0...BLOCK_SIZE - 1).each { |index| block[index] ^= (block[index] << 1) | (block[index + 1] >> 7) }
      block[BLOCK_SIZE - 1] ^= (block[BLOCK_SIZE - 1] << 1) ^ (carry * 0x87)
    end
  end
end
