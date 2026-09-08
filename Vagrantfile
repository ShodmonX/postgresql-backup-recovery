Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"

  nodes = {
    "pg-primary" => {
      ip: "192.168.167.201",
      memory: 2048,
      cpus: 2
    },
    "pg-replica" => {
      ip: "192.168.167.202",
      memory: 2048,
      cpus: 2
    },
    "barman" => {
      ip: "192.168.167.210",
      memory: 2048,
      cpus: 2
    },
    "pg-recovery" => {
      ip: "192.168.167.220",
      memory: 2048,
      cpus: 2
    }
  }

  nodes.each do |name, node|
    config.vm.define name do |machine|
      machine.vm.hostname = name

      machine.vm.network "private_network",
        ip: node[:ip]

      machine.vm.provider "vmware_desktop" do |vmware|
        vmware.memory = node[:memory]
        vmware.cpus = node[:cpus]
      end

      machine.vm.provision "shell", path: "provision/common.sh"

      if name == "pg-primary"
        machine.vm.provision "shell",
        path: "provision/primary.sh",
        env: {
          "PG_REPLICATION_PASSWORD" => ENV.fetch("PG_REPLICATION_PASSWORD", ""),
          "BARMAN_STREAMING_PASSWORD" => ENV.fetch("BARMAN_STREAMING_PASSWORD", "")
        }
      end
    end
  end
end
