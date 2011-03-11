# ===========================================================================
# Copyright (C) 2009, Progress Software Corporation and/or its 
# subsidiaries or affiliates.  All rights reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===========================================================================

require 'command_executor'

class GitRepo < ActiveRecord::Base
  belongs_to :project
  
  def before_save
    project.deploy if use_internal_changed?
  end
    
  def before_destroy
    # TODO: do some archiving of the git repo?
    true
  end
  
  def is_active?
    use_internal? || !external_anonymous_url.blank? || !external_commit_url.blank? 
  end
  
  def commit_url
    use_internal? ? internal_commit_url : external_commit_url
  end

  def anonymous_url
    use_internal? ? internal_anonymous_url : external_anonymous_url
  end

  def web_url
    use_internal? ? internal_web_url : external_web_url
  end
  
  def create_internal()
    return true if not use_internal?
    
    # if GIT_CONFIG[:ssh] is nil, then commands are run locally 
    CommandExecutor.open(GIT_CONFIG[:ssh]) do |x|
    
      # Only create the repo if it does not exist
      if !x.dir_exists?(repo_filepath, git_user)
        x.system("sh -c 'mkdir -p #{repo_filepath} && cd #{repo_filepath} && git --bare init'", git_user)==0 or raise 'Error creating git repo!'
      end      
      x.write("#{project.name}\n", "#{repo_filepath}/description", git_user) 

      # Now update to use or not use the commit mailing list.
      ml = project.mailing_lists.find_by_name("commits")
      x.write(git_config(ml), "#{repo_filepath}/config", git_user) 
      
      if ml
        x.write(". /usr/share/doc/git-core/contrib/hooks/post-receive-email\n", "#{repo_filepath}/hooks/post-receive", git_user) 
        x.system("chmod a+x #{repo_filepath}/hooks/post-receive", git_user)
      else
        x.system("rm #{repo_filepath}/hooks/post-receive", git_user)
      end
      
      x.write(apache_git_file, "#{git_home}/httpd.conf/#{key}")==0 or raise 'Error creating apache conf file!'
      
      x.system('/etc/init.d/apache2 reload', "root")==0 or raise 'Error reloading apache config!'      

    end
        
    true
  end    
  
  #
  # This is usually run by the delayed_job worker.
  #
  def self.export_ssh_keys
    CommandExecutor.open(GIT_CONFIG[:ssh]) do |x|
      require 'tempfile'  
      Tempfile.open('authorized_keys') do |tf|
        # Create the contents of the file.
        User.each_ssh_public_key do |user,key|
          tf.puts "command=\"#{GIT_CONFIG[:forge_git_path]} #{user.login}\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty #{key}"
        end
        tf.flush
        
        git_user=GIT_CONFIG[:user]
        git_home=GIT_CONFIG[:home]        
        x.system("mkdir -p #{git_home}/.ssh", git_user)
        x.copy(tf.path, "#{git_home}/.ssh/authorized_keys.tmp", git_user) ==0 or raise("File copy failed.")
        x.system("chmod 644 #{git_home}/.ssh/authorized_keys.tmp",  git_user)==0 or raise("Chmod failed.")
        x.system("mv #{git_home}/.ssh/authorized_keys.tmp #{git_home}/.ssh/authorized_keys", git_user)==0 or raise("mv failed.")
      end
    end
  end
  
  private
  
  def key
    self.project.shortname.downcase
  end

  def git_user
    GIT_CONFIG[:user]
  end

  def git_home
    GIT_CONFIG[:home]
  end
  
  def git_host
    GIT_CONFIG[:host]
  end

  def repos_filepath
    "#{git_home}/repos"
  end

  def repo_filepath
    "#{repos_filepath}/#{key}.git"
  end
  
  def internal_commit_url
    "ssh://#{git_user}@#{git_host}/#{key}.git"
  end  

  def internal_anonymous_url
    project.is_private? ? "" : "#{FORGE_URL}/git/#{key}.git/"    
  end
  
  def internal_web_url
    project.is_private? ? "" : "#{FORGE_URL}/git/#{key}.git/"    
  end
  
  def git_config(ml)
    rc = """
[core]
  repositoryformatversion = 0
  filemode = true
  bare = true
"""
    if( ml )
      rc << """    
[hooks]
  mailinglist = #{ml.post_address}
  announcelist =
  envelopesender = #{ml.post_address}
  emailprefix = git push:  
"""
    end
  end

  def git_prefix
    "/forge/git"
  end

  def crowd_app_name
    CROWD_CONFIG["http_application_name"]
  end
  def crowd_app_password
    CROWD_CONFIG["http_application_password"]
  end
  def crowd_app_expire
    CROWD_CONFIG["http_application_expire"] || 600
  end

  def write_groups
    groups = "#{CrowdGroup.forge_admin_group.name}"
    self.project.admin_groups.each do |group|
      groups += ",#{group.name}"
    end
    self.project.member_groups.each do |group|
      groups += ",#{group.name}"
    end
    groups
  end
  
  def crowd_auth(groups)
    rc = <<EOF
    AuthType Basic
    AuthName "FUSE Source Login"
    PerlAuthenHandler Apache::CrowdAuth
    PerlSetVar CrowdAppName #{crowd_app_name}
    PerlSetVar CrowdAppPassword #{crowd_app_password}
    PerlSetVar CrowdSOAPURL #{CROWD_URL}/services/SecurityServer
    PerlAuthzHandler Apache::CrowdAuthz
    PerlSetVar CrowdAllowedGroups #{groups}
    PerlSetVar CrowdCacheEnabled on
    PerlSetVar CrowdCacheLocation /var/forge/dav/crowd-cache
    PerlSetVar CrowdCacheExpiry #{crowd_app_expire}
    require valid-user    
EOF
  end
  
  def crowd_write_auth
    crowd_auth(write_groups)
  end
  
  def crowd_read_auth
    groups = write_groups
    self.project.readonly_groups.each do |group|
      groups += ",#{group.name}"
    end
    crowd_auth(groups)
  end
  
  def apache_git_file
    if self.project.is_private
      rc = <<EOF
  <Location #{git_prefix}/#{key}.git/read>
    # private project
    Allow from All
    #{crowd_read_auth}
  </Location>
EOF
    else
      rc = <<EOF
  <Location #{git_prefix}/#{key}.git/read>
    # public project
    Allow from All
  </Location>
EOF
    end
    b = <<EOF
  <Location #{git_prefix}/#{key}.git/write>
    Allow from All
    #{crowd_write_auth}
  </Location>
EOF
    rc += b;
    return rc
  end  

end