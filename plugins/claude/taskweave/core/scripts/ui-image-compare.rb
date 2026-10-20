#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "zlib"

module UIImageCompare
  class Error < StandardError; end

  SCHEMA = "ui-image-comparison-v1"
  MAX_PIXEL_TOLERANCE = 16
  MAX_CHANGED_RATIO = 0.02
  MAX_MEAN_DELTA = 3.0

  module_function

  def compare(source_path, candidate_path, pixel_tolerance: 8, max_changed_ratio: 0.01, max_mean_delta: 2.0)
    validate_thresholds(pixel_tolerance, max_changed_ratio, max_mean_delta)
    source = decode_png(source_path)
    candidate = decode_png(candidate_path)
    raise Error, "source와 candidate PNG 크기가 다릅니다" unless source[:width] == candidate[:width] && source[:height] == candidate[:height]

    changed = 0
    delta_sum = 0
    max_delta = 0
    pixels = source[:pixels].length
    source[:pixels].zip(candidate[:pixels]).each do |left, right|
      deltas = left.zip(right).map { |a, b| (a - b).abs }
      pixel_delta = deltas.max
      changed += 1 if pixel_delta > pixel_tolerance
      delta_sum += deltas.sum
      max_delta = pixel_delta if pixel_delta > max_delta
    end
    changed_ratio = pixels.zero? ? 0.0 : changed.fdiv(pixels)
    mean_delta = pixels.zero? ? 0.0 : delta_sum.fdiv(pixels * 3)
    passed = changed_ratio <= max_changed_ratio && mean_delta <= max_mean_delta

    {
      "schema" => SCHEMA,
      "source_hash" => sha(source_path),
      "candidate_hash" => sha(candidate_path),
      "width" => source[:width],
      "height" => source[:height],
      "thresholds" => {
        "pixel_tolerance" => pixel_tolerance,
        "max_changed_ratio" => max_changed_ratio,
        "max_mean_delta" => max_mean_delta
      },
      "metrics" => {
        "changed_pixels" => changed,
        "total_pixels" => pixels,
        "changed_ratio" => changed_ratio,
        "mean_delta" => mean_delta,
        "max_delta" => max_delta
      },
      "result" => passed ? "passed" : "failed"
    }
  end

  def decode_png(raw_path)
    path = Pathname(raw_path).expand_path
    raise Error, "PNG 파일이 없습니다: #{path}" unless path.file?
    bytes = path.binread
    raise Error, "PNG signature가 아닙니다: #{path}" unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)
    offset = 8
    chunks = Hash.new { |hash, key| hash[key] = [] }
    while offset < bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      type = bytes.byteslice(offset + 4, 4)
      data = bytes.byteslice(offset + 8, length)
      chunks[type] << data
      offset += 12 + length
      break if type == "IEND"
    end
    ihdr = chunks.fetch("IHDR").first
    width, height, bit_depth, color_type, compression, filter, interlace = ihdr.unpack("NNC5")
    raise Error, "8-bit PNG만 지원합니다" unless bit_depth == 8
    raise Error, "지원하지 않는 PNG 압축·필터·인터레이스입니다" unless compression.zero? && filter.zero? && interlace.zero?
    channels = { 0 => 1, 2 => 3, 4 => 2, 6 => 4 }[color_type]
    raise Error, "지원하지 않는 PNG color type입니다: #{color_type}" unless channels
    raw = Zlib::Inflate.inflate(chunks.fetch("IDAT").join)
    stride = width * channels
    rows = []
    previous = Array.new(stride, 0)
    cursor = 0
    height.times do
      filter_type = raw.getbyte(cursor)
      cursor += 1
      encoded = raw.byteslice(cursor, stride).bytes
      cursor += stride
      row = unfilter(encoded, previous, channels, filter_type)
      rows << row
      previous = row
    end
    pixels = rows.flat_map do |row|
      row.each_slice(channels).map { |values| composite_rgb(values, color_type) }
    end
    { width: width, height: height, pixels: pixels }
  rescue KeyError, NoMethodError, Zlib::Error
    raise Error, "손상되었거나 지원하지 않는 PNG입니다: #{path}"
  end

  def unfilter(encoded, previous, bytes_per_pixel, type)
    result = Array.new(encoded.length, 0)
    encoded.each_index do |index|
      left = index >= bytes_per_pixel ? result[index - bytes_per_pixel] : 0
      up = previous[index] || 0
      upper_left = index >= bytes_per_pixel ? previous[index - bytes_per_pixel] : 0
      predictor = case type
                  when 0 then 0
                  when 1 then left
                  when 2 then up
                  when 3 then (left + up) / 2
                  when 4 then paeth(left, up, upper_left)
                  else raise Error, "지원하지 않는 PNG row filter입니다: #{type}"
                  end
      result[index] = (encoded[index] + predictor) & 0xff
    end
    result
  end

  def composite_rgb(values, color_type)
    red, green, blue, alpha = case color_type
                              when 0 then [values[0], values[0], values[0], 255]
                              when 2 then [values[0], values[1], values[2], 255]
                              when 4 then [values[0], values[0], values[0], values[1]]
                              when 6 then values
                              end
    [red, green, blue].map { |channel| ((channel * alpha) + (255 * (255 - alpha))) / 255 }
  end

  def paeth(left, up, upper_left)
    estimate = left + up - upper_left
    distances = [(estimate - left).abs, (estimate - up).abs, (estimate - upper_left).abs]
    [left, up, upper_left][distances.index(distances.min)]
  end

  def validate_thresholds(pixel_tolerance, changed_ratio, mean_delta)
    unless pixel_tolerance.is_a?(Integer) && pixel_tolerance.between?(0, MAX_PIXEL_TOLERANCE)
      raise Error, "pixel tolerance는 0..#{MAX_PIXEL_TOLERANCE}여야 합니다"
    end
    unless changed_ratio.is_a?(Numeric) && changed_ratio.between?(0, MAX_CHANGED_RATIO)
      raise Error, "changed ratio는 0..#{MAX_CHANGED_RATIO}여야 합니다"
    end
    unless mean_delta.is_a?(Numeric) && mean_delta.between?(0, MAX_MEAN_DELTA)
      raise Error, "mean delta는 0..#{MAX_MEAN_DELTA}여야 합니다"
    end
  end

  def sha(path)
    "sha256:#{Digest::SHA256.file(Pathname(path).expand_path).hexdigest}"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { pixel_tolerance: 8, max_changed_ratio: 0.01, max_mean_delta: 2.0 }
  parser = OptionParser.new do |args|
    args.on("--source PATH") { |value| options[:source] = value }
    args.on("--candidate PATH") { |value| options[:candidate] = value }
    args.on("--output PATH") { |value| options[:output] = value }
    args.on("--pixel-tolerance N", Integer) { |value| options[:pixel_tolerance] = value }
    args.on("--max-changed-ratio N", Float) { |value| options[:max_changed_ratio] = value }
    args.on("--max-mean-delta N", Float) { |value| options[:max_mean_delta] = value }
  end
  parser.parse!(ARGV)
  abort "--source, --candidate, --output이 필요합니다" unless options.values_at(:source, :candidate, :output).all?
  begin
    report = UIImageCompare.compare(options[:source], options[:candidate], **options.slice(:pixel_tolerance, :max_changed_ratio, :max_mean_delta))
    output = Pathname(options[:output]).expand_path
    output.dirname.mkpath
    output.write(JSON.generate(report) + "\n")
    puts JSON.generate(report)
    exit(report["result"] == "passed" ? 0 : 1)
  rescue UIImageCompare::Error => error
    warn error.message
    exit 2
  end
end
