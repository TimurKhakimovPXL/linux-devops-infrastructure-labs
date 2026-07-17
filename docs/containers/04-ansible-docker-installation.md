> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

## Goal

Automate the installation of Docker using Ansible following best practices:

---

# 1. Project Structure
```bash
Layout:
ansible/  
├── ansible.cfg  
├── inventory.ini  
├── site.yml  
├── group_vars/  
│ └── docker_hosts.yml  
└── roles/  
└── install_docker/  
├── defaults/main.yml  
├── tasks/main.yml  
└── templates/

### Why this structure?
- variables are separated cleanly  
- role is reusable across hosts  
- inventory file stays minimal  
- ansible.cfg stays project-local (not system-wide)  
```

# 2. ansible.cfg (Local Configuration)

Place this file in the ansible/ directory: 

```
[defaults]
inventory = ./inventory.yml
roles_path = ./roles
pipelining = True
retry_files_enabled = False
vault_password_file = ~/.ansible_vault_pass.txt
host_key_checking = True

[privilege_escalation]
become = True

```

`pipelining=True` improves performance.
Using a **local** config file prevents interference with global settings.
note: best-practice would be to have become=true local in the play that needs it.

## 3. Inventory (inventory.ini)
```
[docker_hosts]
host_ubuntu ansible_host=127.0.0.1 ansible_port=2222
host_debian ansible_host=127.0.0.1 ansible_port=2223
```
All variables go to `group_vars` or `host_vars`

## 4. Group Variables (group_vars/docker_hosts.yml)
```
docker_users:
	- labuser
```

## 5. Role: install_docker

defaults (`roles/install_docker/defaults/main.yml`)
`` docker_repo_url: "https://download.docker.com/linux"``

## 6. Role Tasks (roles/install_docker/tasks/main.yml)

```
- name: Install required packages
  ansible.builtin.apt:
    name:
      - ca-certificates
      - curl
      - gnupg
      - lsb-release
    state: present
    update_cache: yes

- name: Create keyring directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Download Docker GPG key
  ansible.builtin.get_url:
    url: "{{ docker_repo_url }}/{{ ansible_distribution | lower }}/gpg"
    dest: /etc/apt/keyrings/docker.gpg
    mode: "0644"

- name: Add Docker repository
  ansible.builtin.apt_repository:
    repo: >
      deb [arch={{ ansible_architecture }} signed-by=/etc/apt/keyrings/docker.gpg]
      {{ docker_repo_url }}/{{ ansible_distribution | lower }}
      {{ ansible_lsb.codename }} stable
    state: present
    filename: docker

- name: Install Docker Engine
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present
    update_cache: yes

- name: Ensure Docker service is enabled and started
  ansible.builtin.service:
    name: docker
    enabled: yes
    state: started

- name: Add users to docker group
  ansible.builtin.user:
    name: "{{ item }}"
    groups: docker
    append: true
  loop: "{{ docker_users }}"

```

## 7. Playbook (`site.yml`)

```
- name: Install Docker on all hosts
  hosts: docker_hosts
  roles:
    - install_docker
```

## 8. Running the Automation
```
ansible -m ansible.builtin.ping docker_hosts
ansible-playbook site.yml
```

- **Module: `ansible.builtin.apt` (Package Management):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html)
    
- **Module: `ansible.builtin.apt_repository` (Repo Management):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_repository_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_repository_module.html)
    
- **Module: `ansible.builtin.get_url` (Downloading GPG keys):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/get_url_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/get_url_module.html)
    
- **Module: `ansible.builtin.user` (User/Group Management):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html)
    
- **Ansible Best Practices (Directory Layout):** [https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)