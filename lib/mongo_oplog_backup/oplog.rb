module MongoOplogBackup
  module Oplog
    def self.each_document(filename)
      File.open(filename, 'rb') do |stream|
        while !stream.eof?
          yield BSON::Document.from_bson(stream)
        end
      end
    end

    def self.oplog_timestamps(filename)
      timestamps = []
      each_document(filename) do |doc|
        # This can be optimized by only decoding the timestamp
        # (first field), instead of decoding the entire document.
        timestamps << doc['ts']
      end
      timestamps
    end

    FILENAME_RE = /\/oplog-(\d+):(\d+)-(\d+):(\d+)\.bson\z/

    def self.timestamps_from_filename filename
      match = FILENAME_RE.match(filename)
      return nil unless match
      s1 = match[1].to_i
      i1 = match[2].to_i
      s2 = match[3].to_i
      i2 = match[4].to_i
      first = BSON::Timestamp.new(s1, i1)
      last = BSON::Timestamp.new(s2, i2)
      {
        first: first,
        last: last
      }
    end

    def self.merge(target, source_files, options={})
      limit = options[:limit] # TODO: use
      force = options[:force]

      File.open(target, 'wb') do |output|
        last_timestamp = nil
        first = true

        source_files.each do |filename|
          timestamps = timestamps_from_filename(filename)
          if timestamps
            expected_first = timestamps[:first]
            expected_last = timestamps[:last]
          else
            expected_first = nil
            expected_last = nil
          end

          # Optimize:
          # We can assume that the timestamps are in order.
          # This means we only need to find the first non-overlapping point,
          # and the rest we can pass through directly.
          MongoOplogBackup.log.debug "Reading #{filename}"
          last_file_timestamp = nil
          skipped = 0
          wrote = 0
          first_file_timestamp = nil
          Oplog.each_document(filename) do |doc|
            timestamp = doc['ts']
            first_file_timestamp = timestamp if first_file_timestamp.nil?
            if !last_timestamp.nil? && timestamp <= last_timestamp
              skipped += 1
            elsif !last_file_timestamp.nil? && timestamp <= last_file_timestamp
              raise "Timestamps out of order in #{filename}"
            else
              output.write(doc.to_bson)
              wrote += 1
              last_timestamp = timestamp
            end
            last_file_timestamp = timestamp
          end

          if expected_first && first_file_timestamp != expected_first
            raise "#{expected_first} was not the first timestamp in #{filename}"
          end

          if expected_last && last_file_timestamp != expected_last
            raise "#{expected_last} was not the last timestamp in #{filename}"
          end

          MongoOplogBackup.log.info "Wrote #{wrote} and skipped #{skipped} oplog entries from #{filename}"
          raise "Overlap must be exactly 1" unless first || skipped == 1 || force
          first = false
        end
      end
    end

    def self.find_oplogs(dir)
      files = Dir.glob(File.join(dir, 'oplog-*.bson'))
      files.keep_if {|name| name =~ FILENAME_RE}
      files.sort! {|a, b| timestamps_from_filename(a)[:first] <=> timestamps_from_filename(b)[:first]}
      files
    end

    def self.merge_backup(dir)
      oplogs = find_oplogs(dir)
      target = File.join(dir, 'dump', 'oplog.bson')
      FileUtils.mkdir_p(File.join(dir, 'dump'))
      merge(target, oplogs)
    end

  end
end