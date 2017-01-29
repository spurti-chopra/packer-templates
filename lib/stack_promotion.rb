require_relative 'env'
require_relative 'image_metadata_fetcher'

class StackPromotion
  def initialize(stack: '', cur: '', nxt: '')
    @stack = stack
    @cur = cur
    @nxt = nxt
    @cur_image = nil
    @nxt_image = nil
  end

  attr_reader :stack, :cur, :nxt, :cur_image, :nxt_image

  def hydrate!(output_dir: '.')
    output_dir = Pathname.new(output_dir).expand_path
    output_dir.mkpath

    cur_metadata, nxt_metadata = fetch_metadata
    return if cur_metadata.nil? || nxt_metadata.nil?

    create_file_diffs(output_dir, cur_metadata, nxt_metadata)
    create_env_diff(output_dir, cur_metadata.env_hash, nxt_metadata.env_hash)
    create_index_files(output_dir, cur_metadata, nxt_metadata)
  end

  private def fetch_metadata
    @cur_image = latest_image(stack, cur)
    @nxt_image = latest_image(stack, nxt)
    $stdout.puts "---> stack=#{stack} cur=#{cur_image} nxt=#{nxt_image}"

    cur_metadata = fetch_image_metadata_tarball(cur_image)
    nxt_metadata = fetch_image_metadata_tarball(nxt_image)
    if cur_metadata.nil? || nxt_metadata.nil?
      $stdout.puts "     ERROR: missing metadata? cur=#{cur_metadata} nxt=#{nxt_metadata}"
      return [nil, nil]
    end

    cur_metadata.load!
    nxt_metadata.load!

    $stdout.puts "     cur-metadata=#{cur_metadata}"
    $stdout.puts "     nxt-metadata=#{nxt_metadata}"

    [cur_metadata, nxt_metadata]
  end

  private def create_file_diffs(output_dir, cur_metadata, nxt_metadata)
    %w(
      dpkg-manifest.json
      job-board-register.yml
      node-attributes.yml
      system_info.json
      travis_packer_templates_rspec.json
    ).each do |metadata_file|
      next unless cur_metadata.files.key?(metadata_file) &&
                  nxt_metadata.files.key?(metadata_file)
      if metadata_file == 'travis_packer_templates_rspec.json'
        [
          cur_metadata.files[metadata_file],
          nxt_metadata.files[metadata_file]
        ].each do |full_path|
          parsed = JSON.parse(File.read(full_path))
          parsed['examples'] = parsed['examples'].sort_by do |entry|
            entry['full_description']
          end
          File.write(full_path, JSON.pretty_generate(parsed))
        end
      end

      diff_command = %W(
        diff -u
        --label #{cur_image}/#{metadata_file}
        #{cur_metadata.files[metadata_file]}
        --label #{nxt_image}/#{metadata_file}
        #{nxt_metadata.files[metadata_file]}
      )
      diff_filename = output_dir.join("#{metadata_file}.diff")
      $stdout.puts "     writing #{diff_filename}"
      system(*diff_command, out: diff_filename.to_s)
    end
  end

  private def create_env_diff(output_dir, cur_env, nxt_env)
    current_image_env = output_dir.join('current-image.env')
    current_image_env.write(
      cur_env.map { |k, v| [k, v] }.sort
             .map { |e| "#{e[0]}=#{e[1]}" }.join("\n") + "\n"
    )
    next_image_env = output_dir.join('next-image.env')
    next_image_env.write(
      nxt_env.map { |k, v| [k, v] }.sort
             .map { |e| "#{e[0]}=#{e[1]}" }.join("\n") + "\n"
    )
    diff_command = %W(
      diff -u
      --label #{cur_image}/env
      #{current_image_env}
      --label #{nxt_image}/env
      #{next_image_env}
    )
    diff_filename = output_dir.join('env.diff')
    $stdout.puts "     writing #{diff_filename}"
    system(*diff_command, out: diff_filename.to_s)
  end

  private def create_index_files(output_dir, cur_metadata, nxt_metadata)
    packer_templates_diff_url = File.join(
      'https://github.com/travis-ci/packer-templates/compare',
      cur_metadata.env_hash['PACKER_TEMPLATES_SHA'] + '...' +
      nxt_metadata.env_hash['PACKER_TEMPLATES_SHA']
    )

    travis_cookbooks_diff_url = File.join(
      'https://github.com/travis-ci/travis-cookbooks/compare',
      cur_metadata.env_hash['TRAVIS_COOKBOOKS_SHA'] + '...' +
      nxt_metadata.env_hash['TRAVIS_COOKBOOKS_SHA']
    )

    buf = []
    buf << <<-EOF.gsub(/^\s+> ?/, '')
      > # #{stack} promotion report
      >
      > - [packer-templates diff](#{packer_templates_diff_url})
      > - [travis-cookbooks diff](#{travis_cookbooks_diff_url})
      >
    EOF

    output_files = output_dir.children.reject do |child|
      child.directory? || child.basename == 'README.md' ||
        child.basename == 'index.json'
    end

    unless output_files.length.zero?
      buf << '## output files'
      output_files.sort.each do |filename|
        buf << "- [#{filename.basename}](./#{filename.basename})"
      end
    end

    readme = output_dir.join('README.md')
    $stdout.puts "     writing #{readme}"
    readme.write(buf.join("\n"))

    index_json = output_dir.join('index.json')
    $stdout.puts "     writing #{index_json}"
    index_json.write(
      JSON.pretty_generate(
        stack: stack,
        packer_templates_diff_url: packer_templates_diff_url,
        travis_cookbooks_diff_url: travis_cookbooks_diff_url,
        output_files: output_files.map(&:basename).map(&:to_s)
      )
    )
  end

  private def env
    @env ||= Env.new
  end

  private def fetch_image_metadata_tarball(image_name)
    ImageMetadataFetcher.new(image_name: image_name).fetch
  end

  private def latest_image(stack, group)
    q = URI.encode_www_form(
      name: "^travis-ci-#{stack}.*",
      infra: 'gce',
      tags: "group_#{group}:true",
      'fields[images]' => 'name'
    )

    JSON.parse(
      `#{curl_exe} -f -s '#{env['JOB_BOARD_IMAGES_URL']}?#{q}'`
    ).fetch('data').map { |e| e['name'] }.sort.last
  end

  private def curl_exe
    @curl_exe ||= env.fetch('CURL_EXE', 'curl')
  end
end
