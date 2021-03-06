require 'fog'
require 'commander'
require 'rack2aws/config'
require 'rack2aws/version'
require 'rack2aws/processor_count'


module Rack2Aws
  class FileManager
    include Rack2Aws::Configuration

    attr_reader :per_page, :rackspace, :aws, :rackspace_directory, :aws_directory, :nproc, :verbose_mode, :files, :total

    def initialize(options={})
      options = default_options.merge(options)
      @per_page = options[:per_page]
      @rackspace = Fog::Storage.new(RackspaceConfig.load())
      @aws = Fog::Storage.new(AWSConfig.load())

      @rackspace_directory = rackspace.directories.get(options[:rackspace_container])
      @aws_directory = aws.directories.get(options[:aws_bucket])
      @nproc = options[:nproc]
      @verbose_mode = options[:verbose]
      @upload_public = options[:public]
      @files = []
      @total = 0
    end

    def default_options
      { :per_page => 10000, public: false }
    end

    def copy
      time = Time.now
      pages = rackspace_directory.count / per_page + 1
      marker = ''

      # get Rackspace files
      pages.times do |i|
        puts "! Getting page #{i+1}..."
        files = rackspace_directory.files.all(:limit => per_page, :marker => marker).to_a
        puts "! #{files.size} files in page #{i+1}, forking..." if verbose_mode
        pid = fork do
          copy_files(i, files)
        end
        puts "! Process #{pid} forked to copy files" if verbose_mode
        marker = files.last.key
        @total += files.size
      end

      pages.times do
        Process.wait
      end

      puts "--------------------------------------------------"
      puts "! #{total} files copied in #{Time.now - time}secs."
      puts "--------------------------------------------------\n\n"
    end

    def copy_files(page, files)
      puts "  [#{Process.pid}] Page #{page+1}: Copying #{files.size} files..." if verbose_mode
      total = files.size
      process_pids = {}
      time = Time.now

      while !files.empty? or !process_pids.empty?
        while process_pids.size < nproc and files.any? do
          file = files.pop
          pid = Process.fork do
            copy_file(file)
            exit!(0)
          end
          process_pids[pid] = { :file => file }
        end

        if pid_done = Process.wait
          if job_finished = process_pids.delete(pid_done)
            puts "    [#{Process.pid}] Page #{page+1}: Copied #{job_finished[:file].key}." if verbose_mode
          end
        end
      end

      puts "  [#{Process.pid}] ** Page #{page+1}: Copied #{total} files in #{Time.now - time}secs" if verbose_mode
    end

    def copy_file(file)
      aws_directory.files.create(:key          => file.key,
                                 :body         => file.body,
                                 :content_type => file,
                                 :public       => @upload_public)
    end

    private :copy_files, :copy_file
  end

  class CLI
    include Commander::Methods
    include Rack2Aws::ProcessorCount

    def run
      program :name, 'rack2aws'
      program :version, Rack2Aws::VERSION
      program :description, 'Bridge from Rackspace Cloud Files to AWS S3'
      program :help, 'Author', 'Faissal Elamraoui <amr.faissal@gmail.com>'

      global_option('--verbose', 'Explain what is being done') { $verbose = true }

      command :port do |cmd|
        cmd.syntax = 'rack2aws port [options]'
        cmd.description = 'Port files from Rackspace Cloud Files(tm) to AWS S3'

        cmd.option '--container CONTAINER_NAME', String, 'Rackspace Cloud Files container name'
        cmd.option '--bucket BUCKET_NAME', String, 'AWS S3 bucket name'
        cmd.option '--nproc NUM_PROC', Integer, 'Number of processes to fork'
        cmd.option '--public', 'Whether files should be uploaded as public'
        cmd.action do |args, options|
          if options.container.nil?
            options.container = ask('Rackspace Cloud Files container: ')
          end

          if options.bucket.nil?
            options.bucket = ask('AWS S3 bucket: ')
          end

          options.public = !options.public.nil?

          if options.nproc.nil?
            options.nproc = processor_count()
          end

          FileManager.new({
                         :rackspace_container => options.container,
                         :aws_bucket => options.bucket,
                         :nproc => options.nproc,
                         :verbose => $verbose,
                         :public => options.public
                       }).copy
        end
      end
      run!
    end

  end
end
