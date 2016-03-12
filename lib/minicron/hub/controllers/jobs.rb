require 'minicron/transport/ssh'
require 'minicron/cron'

class Minicron::Hub::App
  get '/jobs' do
    # Look up all the jobs
    @jobs = Minicron::Hub::Job.all.order(:created_at => :desc).includes(:host, :executions)

    erb :'jobs/index', :layout => :'layouts/app'
  end

  get '/job/:id' do
    # Look up the job
    @job = Minicron::Hub::Job.includes(:host, :executions, :schedules)
                             .order('executions.number DESC')
                             .find(params[:id])

    erb :'jobs/show', :layout => :'layouts/app'
  end

  get '/jobs/new' do
    # Empty instance to simplify views
    @previous = Minicron::Hub::Job.new

    # All the hosts for the select dropdown
    @hosts = Minicron::Hub::Host.all

    erb :'jobs/new', :layout => :'layouts/app'
  end

  post '/jobs/new' do
    # All the hosts for the select dropdown
    @hosts = Minicron::Hub::Host.all

    begin
      # First we need to look up the host
      host = Minicron::Hub::Host.find(params[:host])

      # Try and save the new job
      job = Minicron::Hub::Job.create!(
        :job_hash => Minicron::Transport.get_job_hash(params[:command], host.fqdn),
        :name => params[:name],
        :command => params[:command],
        :host_id => host.id
      )

      ssh = Minicron::Transport::SSH.new(
        :user => job.host.user,
        :host => job.host.host,
        :port => job.host.port,
        :private_key => "~/.ssh/minicron_host_#{job.host.id}_rsa"
      )

      # Get an instance of the cron class
      cron = Minicron::Cron.new(ssh)

      # Save the job before we look up the hosts jobs so it's changes are there
      job.save!

      # Look up the host and its jobs and job schedules
      host = Minicron::Hub::Host.includes(:jobs => :schedules).find(job.host.id)

      # Update the crontab
      cron.update_crontab(host)

      # Tidy up
      ssh.close

      # Redirect to the new job
      redirect "#{route_prefix}/job/#{job.id}"
    rescue Exception => e
      @previous = params
      flash.now[:error] = e.message
      erb :'jobs/new', :layout => :'layouts/app'
    end
  end

  get '/job/:id/edit' do
    # Find the job
    @job = Minicron::Hub::Job.includes(:host).find(params[:id])

    # All the hosts for the select dropdown
    @hosts = Minicron::Hub::Host.all

    erb :'jobs/edit', :layout => :'layouts/app'
  end

  post '/job/:id/edit' do
    # All the hosts for the select dropdown
    @hosts = Minicron::Hub::Host.all

    begin
      Minicron::Hub::Job.transaction do
        # Find the job
        @job = Minicron::Hub::Job.includes(:host, :schedules).find(params[:id])

        # Update the name and command
        @job.name = params[:name]
        @job.command = params[:command]

        # Update the job on the remote if the user/command has changed
        # Rehash the job command
        @job.job_hash = Minicron::Transport.get_job_hash(@job.command, @job.host.fqdn)

        ssh = Minicron::Transport::SSH.new(
          :user => @job.host.user,
          :host => @job.host.host,
          :port => @job.host.port,
          :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Save the job before we look up the hosts jobs so it's changes are there
        @job.save!

        # Look up the host and its jobs and job schedules
        host = Minicron::Hub::Host.includes(:jobs => :schedules).find(@job.host.id)

        # Update the crontab
        cron.update_crontab(host)

        # Tidy up
        ssh.close

        # Redirect to the updated job
        redirect "#{route_prefix}/job/#{@job.id}"
      end
    rescue Exception => e
      @job.restore_attributes
      flash.now[:error] = e.message
      erb :'jobs/edit', :layout => :'layouts/app'
    end
  end

  post '/job/:id/status/:status' do
    # Find the job
    @job = Minicron::Hub::Job.includes(:host, :executions, :schedules)
                             .order('executions.number DESC')
                             .find(params[:id])

    begin
      Minicron::Hub::Job.transaction do
        # Set if the job is enabled or not
        if params[:status] == 'enable'
          enabled = true
        elsif params[:status] == 'disable'
          enabled = false
        else
          enabled = params[:status] # this will get caught by the AR validation
        end

        # Update the name and user
        @job.enabled = enabled

        ssh = Minicron::Transport::SSH.new(
          :user => @job.host.user,
          :host => @job.host.host,
          :port => @job.host.port,
          :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Save the job before we look up the hosts jobs so it's changes are there
        @job.save!

        # Look up the host and its jobs and job schedules
        host = Minicron::Hub::Host.includes(:jobs => :schedules).find(@job.host.id)

        # Update the crontab
        cron.update_crontab(host)

        # Tidy up
        ssh.close

        # Redirect to the updated job
        redirect "#{route_prefix}/job/#{@job.id}"
      end
    rescue Exception => e
      @job.restore_attributes
      flash.now[:error] = e.message
      erb :'jobs/show', :layout => :'layouts/app'
    end
  end

  post '/job/:id/run' do
    # Find the job
    @job = Minicron::Hub::Job.includes(:host, :executions, :schedules)
                             .order('executions.number DESC')
                             .find(params[:id])

    begin
      ssh = Minicron::Transport::SSH.new(
        :user => @job.host.user,
        :host => @job.host.host,
        :port => @job.host.port,
        :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
      )

      # Get an instance of the cron class
      cron = Minicron::Cron.new(ssh)

      # Run the job manaully
      cron.run(@job)

      # Tidy up
      ssh.close

      # Redirect to the updated job
      flash[:success] = "Job ##{@job.id} run triggered"
      redirect "#{route_prefix}/job/#{@job.id}"
    rescue Exception => e
      flash.now[:error] = e.message
      erb :'jobs/show', :layout => :'layouts/app'
    end
  end

  get '/job/:id/delete' do
    # Look up the job
    @job = Minicron::Hub::Job.find(params[:id])

    erb :'jobs/delete', :layout => :'layouts/app'
  end

  post '/job/:id/delete' do
    # Look up the job
    @job = Minicron::Hub::Job.includes(:schedules).find(params[:id])

    begin
      Minicron::Hub::Job.transaction do
        # Try and delete the job
        Minicron::Hub::Job.destroy(params[:id])

        unless params[:force]
          # Get an ssh instance
          ssh = Minicron::Transport::SSH.new(
            :user => @job.host.user,
            :host => @job.host.host,
            :port => @job.host.port,
            :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
          )

          # Get an instance of the cron class
          cron = Minicron::Cron.new(ssh)

          # Look up the host and its jobs and job schedules
          host = Minicron::Hub::Host.includes(:jobs => :schedules).find(@job.host.id)

          # Update the crontab
          cron.update_crontab(host)

          # Tidy up
          ssh.close
        end

        redirect "#{route_prefix}/jobs"
      end
    rescue Exception => e
      flash.now[:error] =  "<h4>Error</h4>
                            <p>#{e.message}</p>
                            <p>You can force delete the job without connecting to the host</p>"
      erb :'jobs/delete', :layout => :'layouts/app'
    end
  end

  get '/job/:job_id/schedule/:schedule_id' do
    # Look up the schedule
    @schedule = Minicron::Hub::Schedule.includes(:job).find(params[:schedule_id])

    # Look up the job
    @job = @schedule.job

    erb :'jobs/schedules/show', :layout => :'layouts/app'
  end

  get '/job/:job_id/schedules/new' do
    # Empty instance to simplify views
    @previous = Minicron::Hub::Schedule.new

    # Look up the job
    @job = Minicron::Hub::Job.find(params[:job_id])

    erb :'jobs/schedules/new', :layout => :'layouts/app'
  end

  post '/job/:job_id/schedules/new' do
    # Look up the job
    @job = Minicron::Hub::Job.includes(:host, :schedules).find(params[:job_id])

    begin
      # First we need to check a schedule like this doesn't already exist
      exists = Minicron::Hub::Schedule.exists?(
        :minute => params[:minute].empty? ? nil : params[:minute],
        :hour => params[:hour].empty? ? nil : params[:hour],
        :day_of_the_month => params[:day_of_the_month].empty? ? nil : params[:day_of_the_month],
        :month => params[:month].empty? ? nil : params[:month],
        :day_of_the_week => params[:day_of_the_week].empty? ? nil : params[:day_of_the_week],
        :special => params[:special].empty? ? nil : params[:special],
        :job_id => params[:job_id].empty? ? nil : params[:job_id]
      )

      if exists
        raise Minicron::ValidationError, 'That schedule already exists for this job'
      end

      Minicron::Hub::Schedule.transaction do
        # Create the new schedule
        schedule = Minicron::Hub::Schedule.create(
          :minute => params[:minute].empty? ? nil : params[:minute],
          :hour => params[:hour].empty? ? nil : params[:hour],
          :day_of_the_month => params[:day_of_the_month].empty? ? nil : params[:day_of_the_month],
          :month => params[:month].empty? ? nil : params[:month],
          :day_of_the_week => params[:day_of_the_week].empty? ? nil : params[:day_of_the_week],
          :special => params[:special].empty? ? nil : params[:special],
          :job_id => params[:job_id]
        )

        # Get an ssh instance
        ssh = Minicron::Transport::SSH.new(
          :user => @job.host.user,
          :host => @job.host.host,
          :port => @job.host.port,
          :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Save the schedule before looking up the hosts jobs => schedules so the change is there
        schedule.save!

        # Look up the host
        host = Minicron::Hub::Host.includes(:jobs => :schedules).find(@job.host.id)

        # Update the crontab
        cron.update_crontab(host)

        # Tidy up
        ssh.close

        # Redirect to the updated job
        redirect "#{route_prefix}/job/#{@job.id}"
      end
    rescue Exception => e
      flash.now[:error] = e.message
      erb :'jobs/schedules/new', :layout => :'layouts/app'
    end
  end

  get '/job/:job_id/schedule/:schedule_id/edit' do
    # Look up the schedule
    @schedule = Minicron::Hub::Schedule.includes(:job).find(params[:schedule_id])

    # Look up the job
    @job = Minicron::Hub::Job.find(params[:job_id])

    erb :'jobs/schedules/edit', :layout => :'layouts/app'
  end

  post '/job/:job_id/schedule/:schedule_id/edit' do
    # Look up the schedule and job
    @schedule = Minicron::Hub::Schedule.includes(:job => :host).find(params[:schedule_id])

    begin
      # To keep the view similar to #new store the job here
      @job = @schedule.job

      Minicron::Hub::Schedule.transaction do
        old_schedule = @schedule.formatted

        # Get an ssh instance
        ssh = Minicron::Transport::SSH.new(
          :user => @schedule.job.host.user,
          :host => @schedule.job.host.host,
          :port => @schedule.job.host.port,
          :private_key => "~/.ssh/minicron_host_#{@schedule.job.host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Update the instance of the new schedule
        @schedule.minute = params[:minute].empty? ? nil : params[:minute]
        @schedule.hour = params[:hour].empty? ? nil : params[:hour]
        @schedule.day_of_the_month = params[:day_of_the_month].empty? ? nil : params[:day_of_the_month]
        @schedule.month = params[:month].empty? ? nil : params[:month]
        @schedule.day_of_the_week = params[:day_of_the_week].empty? ? nil : params[:day_of_the_week]
        @schedule.special = params[:special].empty? ? nil : params[:special]

        # Save the schedule before looking up the hosts jobs => schedule so the change is there
        @schedule.save!

        # Look up the host and its jobs and job schedules
        host = Minicron::Hub::Host.includes(:jobs => :schedules).find(@job.host.id)

        # Update the crontab
        cron.update_crontab(host)

        # Tidy up
        ssh.close

        # Redirect to the updated job
        redirect "#{route_prefix}/job/#{@schedule.job.id}"
      end
    rescue Exception => e
      @schedule.restore_attributes
      flash.now[:error] = e.message
      erb :'jobs/schedules/edit', :layout => :'layouts/app'
    end
  end

  get '/job/:id/schedule/:schedule_id/delete' do
    # Look up the schedule
    @schedule = Minicron::Hub::Schedule.includes(:job).find(params[:schedule_id])

    erb :'jobs/schedules/delete', :layout => :'layouts/app'
  end

  post '/job/:id/schedule/:schedule_id/delete' do
    # Find the schedule
    @schedule = Minicron::Hub::Schedule.includes(:job => :host).find(params[:schedule_id])

    begin
      Minicron::Hub::Schedule.transaction do
        # Try and delete the schedule
        Minicron::Hub::Schedule.destroy(params[:schedule_id])

        unless params[:force]
          # Get an ssh instance
          ssh = Minicron::Transport::SSH.new(
            :user => @schedule.job.host.user,
            :host => @schedule.job.host.host,
            :port => @schedule.job.host.port,
            :private_key => "~/.ssh/minicron_host_#{@schedule.job.host.id}_rsa"
          )

          # Get an instance of the cron class
          cron = Minicron::Cron.new(ssh)

          # Look up the host and its jobs and job schedules
          host = Minicron::Hub::Host.includes(:jobs => :schedules).find(@schedule.job.host.id)

          # Update the crontab
          cron.update_crontab(host)

          # Tidy up
          ssh.close
        end

        redirect "#{route_prefix}/job/#{@schedule.job.id}"
      end
    rescue Exception => e
      flash.now[:error] =  "<h4>Error</h4>
                            <p>#{e.message}</p>
                            <p>You can force delete the schedule without connecting to the host</p>"
      erb :'jobs/schedules/delete', :layout => :'layouts/app'
    end
  end

  get '/jobs/import/:host' do
    begin
      # Get the host we want to parse the jobs from
      host = Minicron::Hub::Host.find(params[:host])

      # Create an SSH connection
      ssh = Minicron::Transport::SSH.new(
        :user => host.user,
        :host => host.host,
        :port => host.port,
        :private_key => "~/.ssh/minicron_host_#{host.id}_rsa"
      )

      cron = Minicron::Cron.new(ssh)

      # Get the jobs
      crontab_jobs = cron.crontab_jobs(host.name)

      crontab_jobs.each do |cjob|
        # Create the new job...
        job = Minicron::Hub::Job.create!(
          :job_hash => Minicron::Transport.get_job_hash(cjob[:command], host.fqdn),
          :name     => cjob[:name],
          :command  => cjob[:command],
          :host_id  => host.id
        )

        # ... and save it
        job.save!

        # Handle the schedule now
        job_schedule = cjob[:schedule]

        # First we need to check a schedule like this doesn't already exist
        exists = Minicron::Hub::Schedule.exists?(
          :minute           => job_schedule[:minute].nil?           ? nil : job_schedule[:minute],
          :hour             => job_schedule[:hour].nil?             ? nil : job_schedule[:hour],
          :day_of_the_month => job_schedule[:day_of_the_month].nil? ? nil : job_schedule[:day_of_the_month],
          :month            => job_schedule[:month].nil?            ? nil : job_schedule[:month],
          :day_of_the_week  => job_schedule[:day_of_the_week].nil?  ? nil : job_schedule[:day_of_the_week],
          :special          => job_schedule[:special].nil?          ? nil : job_schedule[:special],
          :job_id           => job.id
        )

        if exists
          raise Minicron::ValidationError, 'That schedule already exists for this job'
        end

        Minicron::Hub::Schedule.transaction do
          # Create the new schedule
          schedule = Minicron::Hub::Schedule.create(
            :minute           => job_schedule[:minute].nil?           ? nil : job_schedule[:minute],
            :hour             => job_schedule[:hour].nil?             ? nil : job_schedule[:hour],
            :day_of_the_month => job_schedule[:day_of_the_month].nil? ? nil : job_schedule[:day_of_the_month],
            :month            => job_schedule[:month].nil?            ? nil : job_schedule[:month],
            :day_of_the_week  => job_schedule[:day_of_the_week].nil?  ? nil : job_schedule[:day_of_the_week],
            :special          => job_schedule[:special].nil?          ? nil : job_schedule[:special],
            :job_id           => job.id
          )

          # Save the schedule before looking up the hosts jobs => schedules so the change is there
          schedule.save!
        end
      end

      host = Minicron::Hub::Host.includes(:jobs => :schedules).find(host.id)

      # Update the crontab
      cron.update_crontab(host)

      # Tidy up
      ssh.close

      # Reload the page
      redirect "#{route_prefix}/host/#{host.id}"
    rescue Exception => e
      @host = host
      @previous = params
      flash.now[:error] = e.message
      erb :'hosts/show', :layout => :'layouts/app'
    end
  end
end
