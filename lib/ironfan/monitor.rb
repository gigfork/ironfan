#
#   Copyright (c) 2012-2013 VMware, Inc. All Rights Reserved.
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#

module Ironfan
  module Monitor
    MONITOR_INTERVAL ||= 10

    # VM Status
    STATUS_VM_NOT_EXIST ||= 'Not Exist'
    STATUS_BOOTSTAP_SUCCEED ||= 'Service Ready'
    STATUS_BOOTSTAP_FAIL ||= 'Bootstrap Failed'

    # Actions being performed on VM
    ACTION_CREATE_VM ||= 'Creating VM'
    ACTION_BOOTSTRAP_VM ||= 'Bootstrapping VM'

    # Error Message
    ERROR_BOOTSTAP_FAIL ||= 'Bootstrapping VM failed.'

    def start_monitor_bootstrap(target)
      Chef::Log.debug("Initialize monitoring bootstrap progress of cluster #{target.name}")
      nodes = cluster_nodes(target)
      nodes.each do |node|
        attrs = get_provision_attrs(node)
        attrs[:finished] = false
        attrs[:succeed] = nil
        attrs[:bootstrapped] = false
        attrs[:status] = 'VM Ready'
        attrs[:progress] = 10
        attrs[:action] = ACTION_BOOTSTRAP_VM
        set_provision_attrs(node, attrs)
        node.save
      end

    end

    def start_monitor_progess(target)
      Chef::Log.debug("Initialize monitoring progress of cluster #{target.name}")
      nodes = cluster_nodes(target)
      nodes.each do |node|
        attrs = get_provision_attrs(node)
        attrs[:finished] = false
        attrs[:succeed] = nil
        attrs[:progress] = 0
        attrs[:action] = ''
        set_provision_attrs(node, attrs)
        node.save
      end
    end

    def monitor_iaas_action_progress(target, progress, is_last_action = false)
      progress.result.servers.each do |vm|
        next unless target.include?(vm.name)

        # Get VM attributes
        attrs = vm.to_hash
        # reset to correct status
        if !is_last_action and attrs[:finished] and attrs[:succeed]
          attrs[:finished] = false
          attrs[:succeed] = nil
        end

        # Save progress data to ChefNode
        node = Chef::Node.load(vm.name)
        if (node[:provision] and
            node[:provision][:progress] == attrs[:progress] and
            node[:provision][:action] == attrs[:action])

          Chef::Log.debug("skip updating server #{vm.name} since no progress")
          next
        end
        set_provision_attrs(node, attrs)
        node.save
      end

    end

    def monitor_bootstrap_progress(target, svr, exit_code)
      Chef::Log.debug("Monitoring bootstrap progress of cluster #{target.name} with data: #{[exit_code, svr]}")

      # Save progress data to ChefNode
      node = Chef::Node.load(svr.fullname)
      attrs = get_provision_attrs(node)
      if exit_code == 0
        attrs[:finished] = true
        attrs[:bootstrapped] = true
        attrs[:succeed] = true
        attrs[:status] = STATUS_BOOTSTAP_SUCCEED
        attrs[:error_msg] = ''
      else
        attrs[:finished] = true
        attrs[:bootstrapped] = false
        attrs[:succeed] = false
        attrs[:status] = STATUS_BOOTSTAP_FAIL
        attrs[:error_msg] = ERROR_BOOTSTAP_FAIL
      end
      attrs[:action] = ''
      attrs[:progress] = 100
      set_provision_attrs(node, attrs)
      node.save
    end

    # Monitor the progress of cluster creation
    def monitor_launch_progress(target, progress)
      Chef::Log.debug("Begin reporting progress of launching cluster #{target.name}: #{progress.inspect}")
      monitor_iaas_action_progress(target, progress)
    end

    # report progress of deleting cluster to MessageQueue
    def monitor_delete_progress(target, progress)
      Chef::Log.debug("Begin reporting progress of deleting cluster #{target.name}: #{progress.inspect}")
      monitor_iaas_action_progress(target, progress, true)
    end

    def monitor_config_progress(target, progress)
      Chef::Log.debug("Begin reporting progress of configuring cluster #{target.name}: #{progress.inspect}")
      monitor_iaas_action_progress(target, progress, true)
    end

    # report progress of stopping cluster to MessageQueue
    def monitor_stop_progress(target, progress)
      Chef::Log.debug("Begin reporting progress of stopping cluster #{target.name}: #{progress.inspect}")
      monitor_iaas_action_progress(target, progress, true)
    end

    # report progress of starting cluster to MessageQueue
    def monitor_start_progress(target, progress, is_last_action)
      Chef::Log.debug("Begin reporting progress of starting cluster #{target.name}: #{progress.inspect}")
      monitor_iaas_action_progress(target, progress, is_last_action)
    end

    def get_cluster_name(target_name)
      target_name.split('-')[0]
    end

    def cluster_nodes(target)
      target_name = target.name
      cluster_name = get_cluster_name(target_name)
      nodes = []
      Chef::Search::Query.new.search(:node, "cluster_name:#{cluster_name}") do |n|
        # only return the nodes related to this target
        nodes.push(n) if n.name.start_with?(target_name) and target.include?(n.name)
      end
      raise "Can't find any Chef Nodes belonging to cluster #{target_name}." if nodes.empty?
      nodes.sort_by! { |n| n.name }
    end

    def report_cluster_data(target)
      target.servers.each do |svr|
        vm = svr.fog_server

        node = Chef::Node.load(svr.name.to_s)
        attrs = vm ? JSON.parse(vm.to_hash.to_json) : {}
        attrs.delete("action") unless attrs.empty?
        if vm.nil?
          attrs["status"] = "Not Exist"
          attrs["ip_address"] = nil
        elsif svr.running?
          attrs.delete("status")
          if vm.public_ip_address.nil?
            attrs["status"] = "Powered On"
          else
            attrs["status"] = "VM Ready"
          end
          if node["provision"]["bootstrapped"]
            attrs["status"] = "Service Ready"
          else
            attrs["status"] = "Bootstrap Failed"
          end
        else
          attrs["status"] = "Powered Off"
        end
        set_provision_attrs(node, get_provision_attrs(node).merge(attrs))
        node.save
      end
    end

    protected

    def get_provision_attrs(chef_node)
      chef_node[:provision] ? chef_node[:provision].to_hash : Hash.new
    end

    def set_provision_attrs(chef_node, attrs)
      chef_node[:provision] = attrs
    end

  end
end
