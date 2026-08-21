@[Link("opus")]
lib LibOpus
  alias Encoder = Void

  fun encoder_create = opus_encoder_create(sample_rate : Int32, channels : Int32, application : Int32, error : Int32*) : Encoder*
  fun encode = opus_encode(encoder : Encoder*, pcm : Int16*, frame_size : Int32, output : UInt8*, max_output_bytes : Int32) : Int32
  fun encoder_destroy = opus_encoder_destroy(encoder : Encoder*)
end

module Wumble
  # Produces short mono Opus cues without introducing a decoder or audio asset.
  # A Mumble client configured for stereo duplicates mono Opus into both output
  # channels. Frames are 20 ms, matching the browser's normal Opus packet size.
  module OpusTone
    SAMPLE_RATE       =  48_000
    FRAME_SAMPLES     =     960
    FRAMES_PER_NOTE   =       8
    APPLICATION_AUDIO =    2049
    AMPLITUDE         = 8_000.0

    def self.each_two_tone(first_hz : Float64, second_hz : Float64, &block : Bytes ->)
      error = 0
      encoder = LibOpus.encoder_create(SAMPLE_RATE, 1, APPLICATION_AUDIO, pointerof(error))
      raise "opus_encoder_create failed (#{error})" if encoder.null? || error < 0
      begin
        phase = 0.0
        {first_hz, second_hz}.each do |frequency|
          FRAMES_PER_NOTE.times do |frame_index|
            pcm = Slice(Int16).new(FRAME_SAMPLES)
            FRAME_SAMPLES.times do |sample_index|
              note_sample = frame_index * FRAME_SAMPLES + sample_index
              note_samples = FRAMES_PER_NOTE * FRAME_SAMPLES
              # A short linear attack/release avoids clicks at both frequency
              # transitions without making the cue hard to hear.
              edge = {note_sample, note_samples - note_sample - 1, 240}.min
              envelope = edge / 240.0
              pcm[sample_index] = (Math.sin(phase) * AMPLITUDE * envelope).round.to_i16
              phase += 2.0 * Math::PI * frequency / SAMPLE_RATE
            end
            output = Bytes.new(4_000)
            encoded = LibOpus.encode(encoder, pcm.to_unsafe, FRAME_SAMPLES, output.to_unsafe, output.size)
            raise "opus_encode failed (#{encoded})" if encoded < 0
            yield output[0, encoded].dup
          end
        end
      ensure
        LibOpus.encoder_destroy(encoder)
      end
    end
  end
end
