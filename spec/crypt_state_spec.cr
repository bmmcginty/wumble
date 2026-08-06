require "spec"
require "../src/wumble/crypt_state"

describe Wumble::CryptState do
  it "round trips native UDP packets between the client and server nonce directions" do
    key = Bytes.new(16) { |index| index.to_u8 }
    client_nonce = Bytes.new(16) { |index| (index + 16).to_u8 }
    server_nonce = Bytes.new(16) { |index| (index + 32).to_u8 }
    client = Wumble::CryptState.new(key, client_nonce, server_nonce)
    server = Wumble::CryptState.new(key, server_nonce, client_nonce)

    encrypted = client.encrypt(Bytes[0_u8, 0x08_u8, 0x01_u8])

    server.decrypt(encrypted).should eq(Bytes[0_u8, 0x08_u8, 0x01_u8])
  end
end
