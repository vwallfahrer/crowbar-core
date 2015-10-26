#
# Copyright 2015, SUSE LINUX GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Crowbar
  class Repository
    attr_reader :platform, :id, :config

    class << self
      def load!
        etc_yml = "/etc/crowbar/repos.yml"

        @all_repos = YAML.load_file(Rails.root.join("config/repos.yml"))

        # merge data from etc config file
        etc_repos = {}
        if File.exist? etc_yml
          begin
            etc_repos = YAML.load_file(etc_yml)
          rescue SyntaxError
            # ok, let's live without it
          end
        end

        etc_repos.each do |platform, repos|
          if @all_repos.key? platform
            repos["repos"].each do |id, repo|
              # for repos that exist in our hard-coded file, we only allow
              # overwriting a subset of attributes
              if @all_repos[platform]["repos"].key? id
                %w(url ask_on_error).each do |key|
                  @all_repos[platform]["repos"][id][key] = repo[key] if repo.key? key
                end
              else
                @all_repos[platform]["repos"][id] = repo
              end
            end
          else
            @all_repos[platform] = repos
          end
        end
      end

      def registry
        load! unless defined? @all_repos
        @all_repos
      end

      def where(options = {})
        platform = options.fetch :platform, nil
        repo = options.fetch :repo, nil
        check_all_repos.select do |r|
          if platform
            if repo
              r.platform == platform && r.config["name"] == repo
            else
              r.platform == platform
            end
          else
            r.config["name"] == repo
          end
        end
      end

      def all_platforms
        registry.keys
      end

      def repositories(platform)
        registry[platform]["repos"].keys
      end

      def check_all_repos
        repochecks = []
        all_platforms.each do |platform|
          repositories(platform).each do |repo|
            check = self.new(platform, repo)
            if platform != Crowbar::Product.ses_platform && Crowbar::Product.is_ses?
              #FIXME skip the repo check until SES is ported to SLE12-SP1
              check.config["required"] = "optional"
            end
            repochecks << check
          end
        end
        repochecks
      end

      def provided_and_enabled?(feature, platform = nil)
        answer = false

        if platform.nil?
          all_platforms.each do |p|
            if provided_and_enabled?(feature, p)
              answer = true
              break
            end
          end
        else
          found = false
          answer = true

          repositories(platform).each do |repo|
            provided_features = registry[platform]["repos"][repo]["features"] || []

            next unless provided_features.include? feature
            found = true

            r = self.new(platform, repo)
            answer &&= r.active?
          end

          answer = false unless found
        end

        answer
      end

      def admin_ip
        NodeObject.admin_node.ip
      end

      def web_port
        Proposal.where(barclamp: "provisioner").first.raw_attributes["web_port"]
      end
    end

    def initialize(platform, repo)
      @platform = platform
      @id = repo
      @config = Repository.registry[@platform]["repos"][@id]
    end

    def remote?
      !@config["url"].blank?
    end

    def available?
      remote? || (check_directory && check_repo_tag && check_key_file)
    end

    def exist?
      remote? || check_directory
    end

    def valid_repo?
      remote? || check_repo_tag
    end

    def valid_key_file?
      remote? || check_key_file
    end

    def name
      @config["name"] || @id
    end

    def required
      @config["required"] || "optional"
    end

    def url
      @config["url"] || \
        "http://#{Repository.admin_ip}:#{Repository.web_port}/#{@platform}/repos/#{@config["name"]}/"
    end

    def active?
      active_repos = Chef::DataBag.load("crowbar/repositories") rescue {}
      active_repos.fetch(@platform, {}).key? @id
    end

    def to_databag_hash
      item = Hash.new
      item["name"] = name
      item["url"] = url
      item["ask_on_error"] = @config["ask_on_error"] || false
      item
    end

    private

    def repos_path
      Pathname.new(File.join("/srv/tftpboot", @platform, "repos"))
    end

    def repodata_path
      repos_path.join(@config["name"], "repodata")
    end

    #
    # validation helpers
    #
    def check_directory
      repos_path.join(@config["name"]).directory?
    end

    def check_repo_tag
      expected = @config.fetch("repomd", {})["tag"]
      return true if expected.blank?

      repomd_path = repodata_path.join("repomd.xml")
      if repomd_path.file?
        REXML::Document.new(repomd_path.open).root.elements["tags/repo"].text == expected
      else
        false
      end
    end

    def check_key_file
      expected = @config.fetch("repomd", {})["md5"]
      return true if expected.blank?

      key_path = repodata_path.join("repomd.xml.key")
      if key_path.file?
        md5 = Digest::MD5.hexdigest(key_path.read)
        md5 == expected
      else
        false
      end
    end
  end
end
