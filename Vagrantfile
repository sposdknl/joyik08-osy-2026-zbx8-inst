Vagrant.configure("2") do |config|
  config.vm.box = "bento/debian-13"
  config.vm.hostname = "spos-zabbix8"

  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1", id: "http"
  config.vm.network "forwarded_port", guest: 22, host: 2211, host_ip: "127.0.0.1", id: "ssh"

  config.vm.provider "virtualbox" do |vb|
    vb.name = "vorisekm-zabbix8-debian13"
    vb.cpus = 4
    vb.memory = 4096
  end

  config.vm.provision "file", source: "scripts/", destination: "/tmp/zbx-scripts"

  config.vm.provision "shell", inline: <<-SHELL
    set -euo pipefail
    for f in /tmp/zbx-scripts/*.sh /tmp/zbx-scripts/*.py; do
      sed -i 's/\r$//' "$f"
      chmod +x "$f"
    done
    /tmp/zbx-scripts/install.sh
    python3 /tmp/zbx-scripts/configure_api.py
  SHELL

end
