#
# Cookbook Name:: glance
# Recipe:: api
#
#

include_recipe "#{@cookbook_name}::common"

# Install qemu-img (dependency present in suse packages)
case node[:platform_family]
when "debian"
  package "qemu-utils"
when "rhel", "fedora"
  package "qemu-img"
end

keystone_settings = KeystoneHelper.keystone_settings(node, @cookbook_name)

if node[:glance][:api][:protocol] == "https"
  if node[:glance][:ssl][:generate_certs]
    package "openssl"
    ruby_block "generate_certs for glance" do
      block do
        unless ::File.exist?(node[:glance][:ssl][:certfile]) && ::File.exist?(node[:glance][:ssl][:keyfile])
          require "fileutils"

          Chef::Log.info("Generating SSL certificate for glance...")

          [:certfile, :keyfile].each do |k|
            dir = File.dirname(node[:glance][:ssl][k])
            FileUtils.mkdir_p(dir) unless File.exist?(dir)
          end

          # Generate private key
          `openssl genrsa -out #{node[:glance][:ssl][:keyfile]} 4096`
          if $?.exitstatus != 0
            message = "SSL private key generation failed"
            Chef::Log.fatal(message)
            raise message
          end
          FileUtils.chown "root", node[:glance][:group], node[:glance][:ssl][:keyfile]
          FileUtils.chmod 0640, node[:glance][:ssl][:keyfile]

          # Generate certificate signing requests (CSR)
          conf_dir = File.dirname node[:glance][:ssl][:certfile]
          ssl_csr_file = "#{conf_dir}/signing_key.csr"
          ssl_subject = "\"/C=US/ST=Unset/L=Unset/O=Unset/CN=#{node[:fqdn]}\""
          `openssl req -new -key #{node[:glance][:ssl][:keyfile]} -out #{ssl_csr_file} -subj #{ssl_subject}`
          if $?.exitstatus != 0
            message = "SSL certificate signed requests generation failed"
            Chef::Log.fatal(message)
            raise message
          end

          # Generate self-signed certificate with above CSR
          `openssl x509 -req -days 3650 -in #{ssl_csr_file} -signkey #{node[:glance][:ssl][:keyfile]} -out #{node[:glance][:ssl][:certfile]}`
          if $?.exitstatus != 0
            message = "SSL self-signed certificate generation failed"
            Chef::Log.fatal(message)
            raise message
          end

          File.delete ssl_csr_file  # Nobody should even try to use this
        end # unless files exist
      end # block
    end # ruby_block
  else # if generate_certs
    unless ::File.size? node[:glance][:ssl][:certfile]
      message = "Certificate \"#{node[:glance][:ssl][:certfile]}\" is not present or empty."
      Chef::Log.fatal(message)
      raise message
    end
    # we do not check for existence of keyfile, as the private key is allowed
    # to be in the certfile
  end # if generate_certs

  if node[:glance][:ssl][:cert_required] && !::File.size?(node[:glance][:ssl][:ca_certs])
    message = "Certificate CA \"#{node[:glance][:ssl][:ca_certs]}\" is not present or empty."
    Chef::Log.fatal(message)
    raise message
  end
end

# TODO: there's no dependency in terms of proposal on swift
swift_api_insecure = false
swifts = search(:node, "roles:swift-proxy") || []
if swifts.length > 0
  swift = swifts[0]
  swift_api_insecure = swift[:swift][:ssl][:enabled] && swift[:swift][:ssl][:insecure]
end

#TODO: glance should depend on cinder, but cinder already depends on glance :/
# so we have to do something like this
cinder_api_insecure = false
cinders = search(:node, "roles:cinder-controller") || []
if cinders.length > 0
  cinder = cinders[0]
  cinder_api_insecure = cinder[:cinder][:api][:protocol] == "https" && cinder[:cinder][:ssl][:insecure]
end

#TODO: similarly with nova
use_docker = !search(:node, "roles:nova-compute-docker").empty?

network_settings = GlanceHelper.network_settings(node)

glance_stores = node.default[:glance][:glance_stores]
glance_stores += ["vmware"] unless node[:glance][:vsphere][:host].empty?

# glance_stores unconditionally enables cinder and swift stores, so we need
# to install the necessary clients
package "python-cinderclient"
package "python-swiftclient"

directory node[:glance][:filesystem_store_datadir] do
  owner node[:glance][:user]
  group node[:glance][:group]
  mode 0755
  action :create
end

template node[:glance][:api][:config_file] do
  source "glance-api.conf.erb"
  owner "root"
  group node[:glance][:group]
  mode 0640
  variables(
      bind_host: network_settings[:api][:bind_host],
      bind_port: network_settings[:api][:bind_port],
      registry_bind_host: network_settings[:registry][:bind_host],
      registry_bind_port: network_settings[:registry][:bind_port],
      keystone_settings: keystone_settings,
      rabbit_settings: fetch_rabbitmq_settings,
      swift_api_insecure: swift_api_insecure,
      cinder_api_insecure: cinder_api_insecure,
      use_docker: use_docker,
      glance_stores: glance_stores.join(",")
  )
end

ha_enabled = node[:glance][:ha][:enabled]
my_admin_host = CrowbarHelper.get_host_for_admin_url(node, ha_enabled)
my_public_host = CrowbarHelper.get_host_for_public_url(node, node[:glance][:api][:protocol] == "https", ha_enabled)

# If we let the service bind to all IPs, then the service is obviously usable
# from the public network. Otherwise, the endpoint URL should use the unique
# IP that will be listened on.
if node[:glance][:api][:bind_open_address]
  endpoint_admin_ip = my_admin_host
  endpoint_public_ip = my_public_host
else
  endpoint_admin_ip = my_admin_host
  endpoint_public_ip = my_admin_host
end
api_port = node["glance"]["api"]["bind_port"]
glance_protocol = node[:glance][:api][:protocol]

crowbar_pacemaker_sync_mark "wait-glance_register_service"

keystone_register "register glance service" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  token keystone_settings["admin_token"]
  service_name "glance"
  service_type "image"
  service_description "Openstack Glance Service"
  action :add_service
end

keystone_register "register glance endpoint" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  token keystone_settings["admin_token"]
  endpoint_service "glance"
  endpoint_region keystone_settings["endpoint_region"]
  endpoint_publicURL "#{glance_protocol}://#{endpoint_public_ip}:#{api_port}"
  endpoint_adminURL "#{glance_protocol}://#{endpoint_admin_ip}:#{api_port}"
  endpoint_internalURL "#{glance_protocol}://#{endpoint_admin_ip}:#{api_port}"
#  endpoint_global true
#  endpoint_enabled true
  action :add_endpoint_template
end

crowbar_pacemaker_sync_mark "create-glance_register_service"

glance_service "api"
