> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Install Docker with Ansible

## Goal

Install Docker on Debian and Ubuntu hosts with a small, reusable Ansible role.

---

## 1. Project structure
```text
ansible/
├── ansible.cfg  
├── inventory.ini  
├── site.yml  
├── group_vars/  
│   └── docker_hosts.yml
└── roles/  
    └── install_docker/
        ├── defaults/main.yml
        ├── tasks/main.yml
        └── templates/
```

This keeps variables separate, leaves the inventory small, and makes the role reusable without changing system-wide Ansible configuration.

## 2. Local Ansible configuration

Place this file in the `ansible/` directory:

```ini
[defaults]
inventory = ./inventory.ini
roles_path = ./roles
pipelining = True
retry_files_enabled = False
host_key_checking = True

[privilege_escalation]
become = True
```

`pipelining=True` reduces SSH round trips. A project-local configuration also avoids changing the system-wide Ansible setup. This role does not use vaulted values, so it does not require a vault password file. In a larger project, set `become: true` only on the plays or tasks that need it.

## 3. Inventory (inventory.ini)
```ini
[docker_hosts]
host_ubuntu ansible_host=127.0.0.1 ansible_port=2222 ansible_user=labuser
host_debian ansible_host=127.0.0.1 ansible_port=2223 ansible_user=labuser
```
These loopback addresses and forwarded SSH ports match the two-VM lab. Replace them when the VMs are reached directly. The controller must already have SSH key access, and `labuser` must be allowed to use `sudo`. Keep additional host and group settings in `host_vars` or `group_vars`.

## 4. Group Variables (group_vars/docker_hosts.yml)
```yaml
---
docker_users:
  - labuser
```

## 5. Role: install_docker

defaults (`roles/install_docker/defaults/main.yml`)

```yaml
---
docker_repo_url: "https://download.docker.com/linux"
```

## 6. Role Tasks (roles/install_docker/tasks/main.yml)

```yaml
---
- name: Verify that this role is running on Debian or Ubuntu
  ansible.builtin.assert:
    that:
      - ansible_distribution in ['Debian', 'Ubuntu']
    fail_msg: "The Docker APT repository in this role supports Debian and Ubuntu only."

- name: Install required packages
  ansible.builtin.apt:
    name:
      - ca-certificates
      - curl
    state: present
    update_cache: true

- name: Read the Debian package architecture
  ansible.builtin.command: dpkg --print-architecture
  register: docker_apt_arch
  changed_when: false

- name: Create keyring directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Download Docker GPG key
  ansible.builtin.get_url:
    url: "{{ docker_repo_url }}/{{ ansible_distribution | lower }}/gpg"
    dest: /etc/apt/keyrings/docker.asc
    mode: "0644"

- name: Add Docker repository
  ansible.builtin.apt_repository:
    repo: >
      deb [arch={{ docker_apt_arch.stdout }} signed-by=/etc/apt/keyrings/docker.asc]
      {{ docker_repo_url }}/{{ ansible_distribution | lower }}
      {{ ansible_distribution_release }} stable
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
    update_cache: true

- name: Ensure Docker service is enabled and started
  ansible.builtin.service:
    name: docker
    enabled: true
    state: started

- name: Add users to docker group
  ansible.builtin.user:
    name: "{{ item }}"
    groups: docker
    append: true
  loop: "{{ docker_users }}"
```

## 7. Playbook (`site.yml`)

```yaml
---
- name: Install Docker on all hosts
  hosts: docker_hosts
  roles:
    - install_docker
```

## 8. Run the automation
```bash
ansible -m ansible.builtin.ping docker_hosts
ansible-playbook site.yml
```

Run these commands from the `ansible/` directory on the controller. Users added to the `docker` group need a new login session on each managed host before they can use Docker without `sudo`.

The role converges hosts on the current packages in Docker's stable repository. Exact historical package versions were not recorded; pin them in variables only when those verified version strings are available.

- **Module: `ansible.builtin.apt` (Package Management):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html)
    
- **Module: `ansible.builtin.apt_repository` (Repo Management):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_repository_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_repository_module.html)
    
- **Module: `ansible.builtin.get_url` (Downloading GPG keys):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/get_url_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/get_url_module.html)
    
- **Module: `ansible.builtin.user` (User/Group Management):** [https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html)
    
- **Ansible Best Practices (Directory Layout):** [https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)
