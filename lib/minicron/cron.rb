require 'shellwords'
require 'escape'
require 'securerandom'
require 'digest/sha1'

module Minicron
  # Used to interact with the crontab on hosts over an ssh connection
  class Cron
    PATH = '/bin:/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin'

    # Initialise the cron class
    #
    # @param ssh [Minicron::Transport::SSH] instance
    def initialize(ssh)
      @ssh = ssh
    end

    # Test an SSH connection and the permissions for the crontab
    #
    # @param conn an instance of an open ssh connection
    # @return [Hash]
    def get_host_permissions(conn = nil)
      begin
        # Open an SSH connection
        conn ||= @ssh.open
      rescue
        conn = false
      end

      {
        :connect => conn != false,
      }
    end

    # Test if a host has correct permissions for minicron to operate
    #
    # @param conn an instance of an open ssh connection
    def test_host_permissions(conn)
      begin
        # Test the SSH connection first
        test = get_host_permissions(conn)
      rescue Exception => e
        raise Minicron::CronError, "Error connecting to host, reason: #{e.message}"
      end

      # Check the connection worked
      raise Minicron::CronError, "Unable to connect to host, reason: unknown" if !test[:connect]
    end

    # Build the minicron command to be used in the crontab
    #
    # @param schedule [String]
    # @param command [String]
    # @return [String]
    def build_minicron_command(schedule, command)
      # Escape the command so it will work in bourne shells
      "#{schedule} #{Escape.shell_command(['minicron', 'run', command])}"
    end

    # Build the crontab multiline string that includes all the given jobs
    #
    # @param host [Minicron::Hub::Host] a host instance with it's jobs and job schedules
    # @return [String]
    def build_crontab(host)
      # You have been warned..
      crontab = "#\n"
      crontab += "# This file was automatically generated by minicron at #{Time.now.utc.to_s}, DO NOT EDIT manually!\n"
      crontab += "#\n\n"

      # Set the path to something sensible by default, eventually this should be configurable
      crontab += "# ENV variables\n"
      crontab += "PATH=#{PATH}\n"
      crontab += "MAILTO=\"\"\n"
      crontab += "\n"

      # Add an entry to the crontab for each job schedule
      if host != nil
        host.jobs.each do |job|
          crontab += "# ID:   #{job.id}\n"
          crontab += "# Name: #{job.name}\n"
          crontab += "# Status: #{job.status}\n"

          if job.schedules.length > 0
            job.schedules.each do |schedule|
              crontab += "\t"
              crontab += "# " unless job.enabled # comment out schedule if job isn't enabled
              crontab += "#{build_minicron_command(schedule.formatted, job.command)}\n"
            end
          else
            crontab += "\t# No schedules exist for this job\n"
          end

          crontab += "\n"
        end
      end

      crontab
    end

    # Parse command and schedule from a crontab job
    #
    # @param  job the job as parsed from crontab (includes schedule and command)
    # @return [Hash]
    def parse_job(job)
      # Parse and save each schedule time and the command in a hash
      parsed_job = job.split(" ")

      parsed = {
        :schedule => {
          :minute           => parsed_job[0],
          :hour             => parsed_job[1],
          :day_of_the_month => parsed_job[2],
          :month            => parsed_job[3],
          :day_of_the_week  => parsed_job[4]
        },
        :command => parsed_job[5, parsed_job.length - 1]
      }

      parsed
    end

    # Read the jobs from the crontab of a given host
    #
    # @param  host the name of the host
    # @param  conn an instance of an open ssh connection
    # @return [Array]
    def crontab_jobs(host, conn = nil)
      conn ||= @ssh.open

      test_host_permissions(conn)

      # Read all the file
      crontab = conn.exec!("crontab -l")

      # Parse the content
      crontab_jobs = []
      crontab.to_s.split("\n").each do |line|
        line.strip

        # We only want lines starting with a number or '*' (ignoring spaces)
        next if line.empty? or line !~ /^\s*[0-9*]/

        # Parse and save the jobs
        job = parse_job(line)
        next if job.nil?

        crontab_jobs << {
          :name     => generate_job_name(host, line),
          :command  => job[:command].nil?  ? nil : job[:command].join(" "),
          :schedule => job[:schedule].nil? ? nil : job[:schedule]
        }
      end

      crontab_jobs
    end

    # Generate a name with the maximum of 20 characters
    #
    # @param  host the name of the host
    # @param  job  the job as parsed from crontab (includes schedule and command)
    # @return [String]
    def generate_job_name(host, job)
      "#{host[0..10]}_#{Digest::SHA1.hexdigest(job)[0..10]}"
    end

    # Update the crontab on the given host
    #
    # @param host [Minicron::Hub::Host] a host instance with it's jobs and job schedules
    # @param conn an instance of an open ssh connection
    def update_crontab(host, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # First check if we have the correct permissions we need
      test_host_permissions(conn)

      # Build the new crontab to set
      crontab = build_crontab(host).strip

      # Generate a temporary name for the temp crontab
      tmp_crontab_name = "/tmp/minicron_tmp_crontab_#{SecureRandom.uuid}"

      # Echo the crontab to the tmp crontab file
      conn.exec!("echo #{crontab.shellescape} > #{tmp_crontab_name}").to_s.strip

      # Check that the file has the contents we expect
      tmp_crontab = conn.exec!("cat #{tmp_crontab_name}").to_s.strip

      if tmp_crontab != crontab
        raise Minicron::CronError, "The contents of #{tmp_crontab_name} were not as expected, maybe the file couldn't be written to?"
      end

      # Install the crontab
      conn.exec!("crontab #{tmp_crontab_name}").to_s.strip

      # Check the updated crontab is set to what we expect
      updated_crontab = conn.exec!("crontab -l").to_s.strip

      if updated_crontab != crontab
        raise Minicron::CronError, 'The contents of the updated were not as expected'
      end

      # ..and finally, remove the temp crontab
      conn.exec!("rm #{tmp_crontab_name}").to_s.strip
    end

    # Run a job to run manually
    #
    # @param job [Minicron::Hub::Job]
    # @param conn an instance of an open ssh connection
    def run(job, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # Build the command
      command =  "PATH=#{PATH} "
      command += "#{Escape.shell_command(['minicron', 'run', job.command])}"
      command += " >/dev/null 2>&1 </dev/null &"

      # Exececute the job
      conn.exec!(command)
    end
  end
end
