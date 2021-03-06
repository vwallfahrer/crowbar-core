#
# Copyright (c) 2011 Dell Inc.
# Copyright (c) 2014 SUSE Linux GmbH.
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
#
# Note : This script runs on both the admin and compute nodes.
# It intentionally ignores the bios->enable node data flag.

include_recipe "utils"

unless node[:platform] == "windows" or ::File.exists?("/usr/sbin/ipmitool") or ::File.exists?("/usr/bin/ipmitool")
  package "ipmitool" do
    case node[:platform]
    when "ubuntu","debian"
      package_name "ipmitool"
    when "redhat","centos"
      package_name "OpenIPMI-tools"
    end
    action :install
  end
end

bmc_user     = node[:ipmi][:bmc_user]
bmc_password = node[:ipmi][:bmc_password]
use_dhcp     = node[:ipmi][:use_dhcp]
bmc_address  = node["crowbar"]["network"]["bmc"]["address"] rescue "0.0.0.0"
bmc_netmask  = node["crowbar"]["network"]["bmc"]["netmask"] rescue "0.0.0.0"
bmc_router   = node["crowbar"]["network"]["bmc"]["router"] rescue "0.0.0.0"
bmc_use_vlan = node["crowbar"]["network"]["bmc"]["use_vlan"] rescue false
bmc_vlan     = if bmc_use_vlan
                 node["crowbar"]["network"]["bmc"]["vlan"].to_s
               else
                 "off"
               end

if node["crowbar_wall"]["status"]["ipmi"]["user_set"].nil?
  node.set["crowbar_wall"]["status"]["ipmi"]["user_set"] = false
  node.set["crowbar_wall"]["status"]["ipmi"]["address_set"] = false
  node.save
end

unsupported = ["KVM", "Bochs", "VMWare Virtual Platform", "VMware Virtual Platform", "VirtualBox"]

if node[:ipmi][:bmc_enable]
  if unsupported.member?(node[:dmi][:system][:product_name])
    node.set["crowbar_wall"]["status"]["ipmi"]["messages"] = ["Unsupported platform: #{node[:dmi][:system][:product_name]} - turning off ipmi for this node"]
    node.set[:ipmi][:bmc_enable] = false
    node.save
    return
  end

  unless (node["crowbar_wall"]["status"]["ipmi"]["address_set"] and node["crowbar_wall"]["status"]["ipmi"]["user_set"])
    node["crowbar_wall"]["status"]["ipmi"]["messages"] = []
    node.save

    unless node[:platform] == "windows"
      ipmi_load "ipmi_load" do
        settle_time 30
        action :run
      end
    end
  end

  unless node[:platform] == "windows" or node["crowbar_wall"]["status"]["ipmi"]["address_set"]
    if use_dhcp
      ### lan parameters to check and set. The loop that follows iterates over this array.
      # [0] = name in "print" output, [1] command to issue, [2] desired value.
      lan_params = [
        ["IP Address Source" ,"ipmitool lan set #{node["crowbar_wall"]["ipmi"]["channel"]} ipsrc dhcp", "DHCP Address", 60]
      ]

      lan_params.each do |param|
        ipmi_lan_set "#{param[0]}" do
          command param[1]
          value param[2]
          settle_time param[3]
          action :run
        end
      end

      node.set["crowbar_wall"]["status"]["ipmi"]["address_set"] = true
      node.save
    else
      ### lan parameters to check and set. The loop that follows iterates over this array.
      # [0] = name in "print" output, [1] command to issue, [2] desired value.
      lan_params = [
        ["IP Address Source" ,"ipmitool lan set #{node["crowbar_wall"]["ipmi"]["channel"]} ipsrc static", "Static Address", 10] ,
        ["IP Address" ,"ipmitool lan set #{node["crowbar_wall"]["ipmi"]["channel"]} ipaddr #{bmc_address}", bmc_address, 1] ,
        ["Subnet Mask" , "ipmitool lan set #{node["crowbar_wall"]["ipmi"]["channel"]} netmask #{bmc_netmask}", bmc_netmask, 1] ,
        ["Default VLAN", "ipmitool lan set #{node["crowbar_wall"]["ipmi"]["channel"]} vlan id #{bmc_vlan}", bmc_vlan, 10]
      ]

      lan_params << ["Default Gateway IP", "ipmitool lan set #{node["crowbar_wall"]["ipmi"]["channel"]} defgw ipaddr #{bmc_router}", bmc_router, 1] unless bmc_router.nil? || bmc_router.empty?

      lan_params.each do |param|
        ipmi_lan_set "#{param[0]}" do
          command param[1]
          value param[2]
          settle_time param[3]
          action :run
        end
      end
    end
  end

  unless node[:platform] == "windows" or node["crowbar_wall"]["status"]["ipmi"]["user_set"]
    ipmi_user_set "#{bmc_user}" do
      password bmc_password
      action :run
    end
  end

  unless node[:platform] == "windows"
    ipmi_unload "ipmi_unload" do
      action :run
    end
  end

end

