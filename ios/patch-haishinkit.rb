# Patches HaishinKit 2.0.x in-place inside Pods/HaishinKit to fix RTMP playback
# audio corruption (robotic/metallic voice caused by shared AVAudioCompressedBuffer
# overwrite and unstructured Task packet reordering).

def patch_haishinkit_sources!(pods_root)
  return unless pods_root && Dir.exist?(pods_root.to_s)

  conn_path = File.join(pods_root.to_s, 'HaishinKit/HaishinKit/Sources/RTMP/RTMPConnection.swift')
  if File.exist?(conn_path)
    src = File.read(conn_path)
    patched = src.gsub(
      'Task { await stream.dispatch(message, type: type) }',
      'await stream.dispatch(message, type: type)'
    )
    # Preserve the initial chunk header type (e.g. Type 0 absolute timestamp)
    # when a multi-chunk message (such as a video keyframe) finishes on a
    # Type 3 continuation chunk; otherwise RTMPTimestamp adds the absolute
    # timestamp as a delta and corrupts A/V sync.
    patched = patched.sub(
      'await dispatch(message, type: chunkType)',
      'await dispatch(message, type: messageHeader.initialChunkType)'
    )
    if patched != src
      File.chmod(0644, conn_path)
      File.write(conn_path, patched)
    end
  end

  stream_path = File.join(pods_root.to_s, 'HaishinKit/HaishinKit/Sources/RTMP/RTMPStream.swift')
  if File.exist?(stream_path)
    src = File.read(stream_path)
    patched = src

    # 1. Allocate audioBuffer during both .play and .playing so an AAC sequence
    #    header arriving before play()'s continuation resumes is never dropped.
    patched = patched.sub(
      "            case .playing:\n                if let audioFormat {",
      "            case .play, .playing:\n                if let audioFormat {"
    )

    # 2. Make dispatch(_:type:) async so RTMPConnection can await it in wire order.
    patched = patched.sub(
      '    func dispatch(_ message: some RTMPMessage, type: RTMPChunkType) {',
      '    func dispatch(_ message: some RTMPMessage, type: RTMPChunkType) async {'
    )
    patched = patched.sub(
      "        case let message as RTMPAudioMessage:\n            append(message, type: type)\n        case let message as RTMPVideoMessage:\n            append(message, type: type)",
      "        case let message as RTMPAudioMessage:\n            await append(message, type: type)\n        case let message as RTMPVideoMessage:\n            await append(message, type: type)"
    )

    # 3. Allocate a fresh AVAudioCompressedBuffer per audio packet and await
    #    incoming.append in FIFO order instead of overwriting a single shared
    #    self.audioBuffer across unstructured Tasks.
    patched = patched.sub(
      '    private func append(_ message: RTMPAudioMessage, type: RTMPChunkType) {',
      '    private func append(_ message: RTMPAudioMessage, type: RTMPChunkType) async {'
    )
    patched = patched.sub(
      "            if let audioBuffer {\n                message.copyMemory(audioBuffer)\n                Task { await incoming.append(audioBuffer, when: audioTimestamp.value) }\n            }",
      "            if let audioFormat {\n                let maxPacketSize = max(1024 * Int(audioFormat.channelCount), message.payload.count)\n                let buffer = AVAudioCompressedBuffer(format: audioFormat, packetCapacity: 1, maximumPacketSize: maxPacketSize)\n                message.copyMemory(buffer)\n                await incoming.append(buffer, when: audioTimestamp.value)\n            }"
    )

    # 4. Await incoming.append for video in wire order as well.
    patched = patched.sub(
      '    private func append(_ message: RTMPVideoMessage, type: RTMPChunkType) {',
      '    private func append(_ message: RTMPVideoMessage, type: RTMPChunkType) async {'
    )
    patched = patched.gsub(
      'Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }',
      'await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat)'
    )

    if patched != src
      File.chmod(0644, stream_path)
      File.write(stream_path, patched)
    end
  end

  chunk_path = File.join(pods_root.to_s, 'HaishinKit/HaishinKit/Sources/RTMP/RTMPChunk.swift')
  if File.exist?(chunk_path)
    src = File.read(chunk_path)
    patched = src
    unless patched.include?('var hasExtendedTimestamp')
      patched = patched.sub(
        "    var timestamp: UInt32 = 0\n    var messageLength: Int = 0 {",
        "    var timestamp: UInt32 = 0\n    var hasExtendedTimestamp = false\n    var messageLength: Int = 0 {"
      )
    end
    unless patched.include?('var initialChunkType')
      patched = patched.sub(
        "    var timestamp: UInt32 = 0\n",
        "    var timestamp: UInt32 = 0\n    var initialChunkType: RTMPChunkType = .zero\n"
      )
    end
    unless patched.include?('fileprivate var position = 0')
      patched = patched.sub(
        '    private var position = 0',
        '    fileprivate var position = 0'
      )
    end
    unless patched.include?('messageHeader.initialChunkType = type')
      patched = patched.sub(
        "        if remaining < type.headerSize {\n            throw RTMPChunkError.bufferUnderflow\n        }\n        switch type {",
        "        if remaining < type.headerSize {\n            throw RTMPChunkError.bufferUnderflow\n        }\n        if messageHeader.position == 0 {\n            messageHeader.initialChunkType = type\n        }\n        switch type {"
      )
    end
    patched = patched.sub(
      "    func getBasicHeader() throws -> (RTMPChunkType, UInt16) {\n        let rawValue = (data[position] & 0b11000000) >> 6",
      "    func getBasicHeader() throws -> (RTMPChunkType, UInt16) {\n        if remaining < 1 {\n            throw RTMPChunkError.bufferUnderflow\n        }\n        let rawValue = (data[position] & 0b11000000) >> 6"
    )
    patched = patched.sub(
      "        case 0:\n            defer {",
      "        case 0:\n            if remaining < 2 {\n                throw RTMPChunkError.bufferUnderflow\n            }\n            defer {"
    )
    patched = patched.sub(
      "        case 1:\n            defer {",
      "        case 1:\n            if remaining < 3 {\n                throw RTMPChunkError.bufferUnderflow\n            }\n            defer {"
    )
    patched = patched.sub(
      "        if messageHeader.timestamp == RTMPChunkMessageHeader.maxTimestamp {",
      "        if type != .three {\n            messageHeader.hasExtendedTimestamp = messageHeader.timestamp == RTMPChunkMessageHeader.maxTimestamp\n        }\n        if messageHeader.hasExtendedTimestamp {"
    )
    if patched != src
      File.chmod(0644, chunk_path)
      File.write(chunk_path, patched)
    end
  end

  media_link_path = File.join(pods_root.to_s, 'HaishinKit/HaishinKit/Sources/HKStream/MediaLink.swift')
  if File.exist?(media_link_path)
    src = File.read(media_link_path)
    patched = src
    # Bypass MediaLink's free-running display-link duration counter when no
    # HaishinKit AudioPlayerNode is attached so PlayerView can synchronize
    # video frames directly against the hardware AVAudioPlayerNode clock.
    unless patched.include?('if audioPlayer == nil')
      patched = patched.sub(
        "    func enqueue(_ sampleBuffer: CMSampleBuffer) {\n        guard isRunning else {\n            return\n        }",
        "    func enqueue(_ sampleBuffer: CMSampleBuffer) {\n        guard isRunning else {\n            return\n        }\n        if audioPlayer == nil {\n            continutation?.yield(sampleBuffer)\n            return\n        }"
      )
    end
    if patched != src
      File.chmod(0644, media_link_path)
      File.write(media_link_path, patched)
    end
  end
end
