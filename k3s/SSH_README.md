# Instructions
### Ansible User
1. Create user fedora
2. Set password for fedora
3. Grant fedora necessary permissions

### SSH Key Generation
1. Enable sshd - openssh-server
2. generate ssh key
3. ssh-add ssh key (optional)
4. ssh-copy-id -i /path/to/key fedora@hostname-i

### Run ansible
1. ansible-playbook site.yaml -kK
