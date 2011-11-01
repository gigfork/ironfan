module ClusterChef

  #
  # A server is a specific (logical) member of a facet within a cluster.
  #
  # It may have extra attributes if it also exists in the Chef server,
  # or if it exists in the real world (as revealed by Fog)
  #
  class Server < ClusterChef::ComputeBuilder
    attr_reader   :cluster, :facet, :facet_index
    attr_accessor :chef_node, :fog_server

    @@all ||= Mash.new

    def initialize facet, idx
      @cluster     = facet.cluster
      @facet       = facet
      @facet_index = idx
      @fullname    = [cluster_name, facet_name, facet_index].join('-')
      super(@fullname)
      @tags = { "cluster" => cluster_name, "facet"   => facet_name, "index"   => facet_index }
      ui.warn("Duplicate server #{[self, facet.name, idx]} vs #{@@all[fullname]}") if @@all[fullname]
      @@all[fullname] = self
    end

    def fullname fn=nil
      @fullname = fn if fn
      @fullname
    end

    def cluster_name
      cluster.name
    end

    def facet_name
      facet.name
    end

    def servers
      ClusterChef::ServerGroup.new(cluster, [self])
    end

    def bogosity val=nil
      @settings[:bogosity] = val  if not val.nil?
      return @settings[:bogosity] if not @settings[:bogosity].nil?
      return :bogus_facet         if facet.bogus?
      # return :out_of_range      if (self.facet_index.to_i >= facet.instances)
      false
    end

    def in_cloud?
      !! fog_server
    end

    def in_chef?
      chef_node || chef_client
    end

    def has_cloud_state?(*states)
      in_cloud? && states.flatten.include?(fog_server.state)
    end

    def exists?
      created? || in_chef?
    end

    # Server is syncable if it is not bogus (exists in cluster definition)
    def syncable?
      not bogus?
    end

    def created?
      in_cloud? && (not ['terminated', 'shutting-down'].include?(fog_server.state))
    end

    def running?
      has_cloud_state?('running')
    end

    def startable?
      has_cloud_state?('stopped')
    end

    def launchable?
      not created?
    end

    def sshable?
      in_chef?
    end

    def killable?
      in_chef? || created?
    end

    def to_s
      super[0..-3] + " chef: #{in_chef? && chef_node.name} fog: #{in_cloud? && fog_server.id}}>"
    end

    #
    # Attributes
    #

    def tag key, value=nil
      if value then @tags[key] = value ; end
      @tags[key]
    end

    #
    # Resolve:
    #
    def resolve!
      reverse_merge!(facet)
      reverse_merge!(cluster)
      @settings[:run_list] = (@cluster.run_list + @facet.run_list + self.run_list).uniq
      #
      cloud.reverse_merge!(facet.cloud)
      cloud.reverse_merge!(cluster.cloud)
      #
      cloud.user_data({
          :chef_server            => Chef::Config.chef_server_url,
          :validation_client_name => Chef::Config.validation_client_name,
          #
          :node_name              => fullname,
          :cluster_name           => cluster_name,
          :facet_name             => facet_name,
          :facet_index            => facet_index,
          #
          :run_list               => run_list,
        })
      #
      if client_key.body then cloud.user_data({ :client_key     => client_key.body, })
      else                    cloud.user_data({ :validation_key => cloud.validation_key }) ; end
      cloud.keypair(cluster_name) if cloud.keypair.nil?
      #
      self
    end

    #
    # This prepares a composited view of the volumes -- it shows the cluster
    # definition overlaid by the facet definition overlaid by the server
    # definition.
    #
    # This method *does* auto-vivify an empty volume declaration on the server,
    # but doesn't modify it.
    #
    # This code is pretty smelly, but so is the resolve! behavior. advice welcome.
    #
    def composite_volumes
      vols = {}
      facet.volumes.each do |vol_name, vol|
        self.volumes[vol_name] ||= ClusterChef::Volume.new(:parent => self, :name => vol_name)
        vols[vol_name]         ||= self.volumes[vol_name].dup
        vols[vol_name].reverse_merge!(vol)
      end
      cluster.volumes.each do |vol_name, vol|
        self.volumes[vol_name] ||= ClusterChef::Volume.new(:parent => self, :name => vol_name)
        vols[vol_name]         ||= self.volumes[vol_name].dup
        vols[vol_name].reverse_merge!(vol)
      end
      vols.each{|vol_name, vol| vol.availability_zone self.default_availability_zone }
      vols
    end

    # FIXME -- this will break on some edge case wehre a bogus node is
    # discovered after everything is resolve!d
    def default_availability_zone
      cloud.default_availability_zone
    end

    #
    # retrieval
    #
    def self.get(cluster_name, facet_name, facet_index)
      cluster = ClusterChef.cluster(cluster_name)
      had_facet = cluster.has_facet?(facet_name)
      facet = cluster.facet(facet_name)
      facet.bogosity true unless had_facet
      had_server = facet.has_server?( facet_index )
      server = facet.server(facet_index)
      server.bogosity :not_defined_in_facet unless had_server
      return server
    end

    def self.all
      @@all
    end

    #
    # Actions!
    #

    def sync_to_cloud
      step "Syncing to cloud", :blue
      attach_volumes
      create_tags
      associate_public_ip
    end

    def sync_to_chef
      step "Syncing to chef server", :blue
      ensure_chef_client
      ensure_chef_node
      # check_node_permissions # _acl API not working, skipping it
      chef_set_attributes
      sync_volume_attributes
      save_chef_node
      true
    end

    def sync_volume_attributes
      composite_volumes.each do |vol_name, vol|
        chef_node.normal[:mountable_volumes][:volumes] ||= Mash.new
        chef_node.normal[:mountable_volumes][:volumes][vol_name] = vol.to_mash.compact
      end
    end

    # FIXME: a lot of AWS logic in here. This probably lives in the facet.cloud
    # but for the one or two things that come from the facet
    def create_server
      return nil if created? # only create a server if it does not already exist
      fog_create_server
    end

    def create_tags
      return unless created?
      step("  labeling servers and volumes")
      fog_create_tags(fog_server, self.fullname, { "name" => name, "cluster" => cluster_name, "facet"   => facet_name, "index"   => facet_index, })
      composite_volumes.each do |vol_name, vol|
        if vol.fog_volume
          fog_create_tags(vol.fog_volume, vol.desc,
            { "server" => self.fullname, "name" => "#{name}-#{vol.name}", "device" => vol.device, "mount_point" => vol.mount_point, "cluster" => cluster_name, "facet"   => facet_name, "index"   => facet_index, })
        end
      end
    end

    def block_device_mapping
      composite_volumes.values.map(&:block_device_mapping).compact
    end

  end
end
