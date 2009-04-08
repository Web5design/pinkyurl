load 'deploy' if respond_to?(:namespace) # cap2 differentiator
Dir['vendor/plugins/*/recipes/*.rb'].each { |plugin| load(plugin) }

set :application, "pinkyurl"
set :scm, "git"
set :repository, "git://github.com/visnup/pinkyurl.git"
set :deploy_via, :remote_cache

set :user, "app"
set :use_sudo, false

role :app, "li82-54.members.linode.com"

namespace :deploy do
  task :restart, :roles => :app do
    run "touch #{current_path}/tmp/restart.txt"
  end

  task :finalize_update, :roles => :app do
  end
end
