require 'capistrano/gitflow/natcmp'
require 'stringex'

namespace :gitflow do
  def last_tag_matching(pattern,second_to_last=nil)
    matching_tags = `git tag -l '#{pattern}'`.split
    matching_tags.sort! do |a,b|
      String.natcmp(b, a, true)
    end

    last_tag = if matching_tags.length > 0
                 second_to_last ? matching_tags[1] : matching_tags[0]
               else
                 nil
               end
  end

  def last_staging_tag(second_to_last=nil)
    last_tag_matching('staging-*',second_to_last)
  end

  def next_staging_tag
    hwhen = Time.now.strftime('%Y-%m-%d_%H-%M-%S')

    last_staging_tag = last_tag_matching("staging-#{hwhen}-*")
    new_tag_serial = if last_staging_tag && last_staging_tag =~ /staging-[0-9]{4}-[0-9]{2}-[0-9]{2}\-([0-9]*)/
                       $1.to_i + 1
                     else
                       1
                     end

    "#{stage}-#{hwhen}-#{new_tag_serial}"
  end

  def last_production_tag(second_to_last=nil)
    last_tag_matching('production-*',second_to_last)
  end

  def using_git?
    fetch(:scm, :git).to_sym == :git
  end

  def stage
    fetch(:stage)
  end

  def local_branch
    fetch(:local_branch)
  end

  def deliver_stories(commits)
    # This is a commit message [Finishes #77090594]
    stories = []
    commits.split("\n").each do |commit|
      id = commit[/\[.+#([0-9]+)\]/, 1]
      stories << id unless id.nil?
    end

    unless stories.empty? || fetch(:pivotal_tracker_token).nil? || fetch(:pivotal_tracker_project_id).nil?
      PivotalTracker::Client.token = fetch(:pivotal_tracker_token)
      project = PivotalTracker::Project.find(fetch(:pivotal_tracker_project_id))
      stories.each do |story_id|
        story = project.stories.find(story_id)
        story.update(current_state: 'delivered') if story && story.current_state == 'finished'
      end
    end
  end

  task :verify_up_to_date do
    if using_git?
      set :local_branch, `git branch --no-color 2> /dev/null | sed -e '/^[^*]/d'`.gsub(/\* /, '').chomp
      local_sha = `git log --pretty=format:%H HEAD -1`.chomp
      origin_sha = `git log --pretty=format:%H #{local_branch} -1`
      unless local_sha == origin_sha
        abort """
Your #{local_branch} branch is not up to date with origin/#{local_branch}.
Please make sure you have pulled and pushed all code before deploying:

git pull origin #{local_branch}
# run tests, etc
git push origin #{local_branch}

"""
      end
    end
  end

  desc "Calculate the tag to deploy"
  task :calculate_tag do
    if using_git?
      # make sure we have any other deployment tags that have been pushed by others so our auto-increment code doesn't create conflicting tags
      `git fetch`

      unless Rake::Task["gitflow:tag_#{stage}"].nil?
        invoke "gitflow:tag_#{stage}"

        system "git push --tags origin #{local_branch}"
        if $? != 0
          abort "git push failed"
        end
      end
    end
  end

  desc "Show log between most recent staging tag (or given tag=XXX) and last production release."
  task :commit_log do
    from_tag = if stage == :production
                 last_production_tag
               elsif stage == :staging
                 last_staging_tag
               else
                 abort "Unsupported stage #{stage}"
               end

    to_tag = ENV['TAG']
    to_tag ||= begin
                 puts "Calculating 'end' tag for :commit_log for '#{stage}'"
                 to_tag = if stage == :production
                            last_staging_tag
                          elsif stage == :staging
                            'master'
                          else
                            abort "Unsupported stage #{stage}"
                          end
               end


    command = if `git config remote.origin.url` =~ /git@github.com:(.*)\/(.*).git/
                "open https://github.com/#{$1}/#{$2}/compare/#{from_tag}...#{to_tag || 'master'}"
              else
                log_subcommand = if ENV['git_log_command'] && ENV['git_log_command'].strip != ''
                                   ENV['git_log_command']
                                 else
                                   'log'
                                 end
                "git #{log_subcommand} #{fromTag}..#{toTag}"
              end
    puts command
    system command
  end

  desc "Mark the current code as a staging/qa release"
  task :tag_staging do
    current_sha = `git log --pretty=format:%H HEAD -1`
    last_staging_tag_sha = if last_staging_tag
                             `git log --pretty=format:%H #{last_staging_tag} -1`
                           end

    if last_staging_tag_sha == current_sha
      puts "Not re-tagging staging because latest tag (#{last_staging_tag}) already points to HEAD"
      new_staging_tag = last_staging_tag
    else
      new_staging_tag = next_staging_tag
      puts "Tagging current branch for deployment to staging as '#{new_staging_tag}'"
      system "git tag -a -m 'tagging current code for deployment to staging' #{new_staging_tag}"
    end

    set :branch, new_staging_tag
  end

  desc "Push the approved tag to production. Pass in tag to deploy with 'TAG=staging-YYYY-MM-DD-X-feature'."
  task :tag_production do
    promote_to_production_tag = ENV['TAG'] || last_staging_tag

    unless promote_to_production_tag && promote_to_production_tag =~ /staging-.*/
      abort "Couldn't find a staging tag to deploy; use '-s tag=staging-YYYY-MM-DD.X'"
    end
    unless last_tag_matching(promote_to_production_tag)
      abort "Staging tag #{promote_to_production_tag} does not exist."
    end

    promote_to_production_tag =~ /^staging-(.*)$/
    new_production_tag = "production-#{$1}"

    if new_production_tag == last_production_tag
      puts "Not re-tagging #{last_production_tag} because it already exists"
      ask(:really_deploy, "Do you really want to deploy #{last_production_tag}? [y/N]")
      really_deploy = fetch(:really_deploy)

      exit(1) unless really_deploy =~ /^[Yy]$/
    else
      puts "Preparing to promote staging tag '#{promote_to_production_tag}' to '#{new_production_tag}'"
      unless ENV['TAG']
        ask(:really_deploy, "Do you really want to deploy #{new_production_tag}? [y/N]")
        really_deploy = fetch(:really_deploy)

        exit(1) unless really_deploy =~ /^[Yy]$/
      end
      puts "Promoting staging tag #{promote_to_production_tag} to production as '#{new_production_tag}'"
      system "git tag -a -m 'tagging current code for deployment to production' #{new_production_tag} #{promote_to_production_tag}"
    end

    set :branch, new_production_tag
  end

  desc "Write commit log as release note"
  task :write_release_note do
    on roles(:app) do
      last_tag = second_last_tag = nil
      if stage == :staging
        last_tag = last_staging_tag
        second_last_tag = last_staging_tag(true)
      else
        last_tag = last_production_tag
        second_last_tag = last_production_tag(true)
      end

      commits = `git log --pretty=format:"%h %s (%an)" #{second_last_tag}...#{last_tag}`
      deliver_stories(commits)
      release_note = <<-TEXT
Date: #{Time.now}
Tag: #{last_tag}

Commits:
#{commits}
TEXT
      release_note.gsub!("\"","'")
      release_note.force_encoding("ASCII-8BIT")
      release_note_path = "#{release_path}/public/release_note.txt"
      execute :echo, "\"#{release_note}\"", '>', release_note_path
    end
  end
end

namespace :deploy do
  namespace :pending do
    task :compare do
      gitflow.commit_log
    end
  end
end

before "deploy:updating", "gitflow:calculate_tag"
before "gitflow:calculate_tag", "gitflow:verify_up_to_date"
after  "deploy:updated", "gitflow:write_release_note"
