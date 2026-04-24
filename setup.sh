mkdir -p ~/htcondor-ansible/{group_vars,templates,test_job}
cd ~/htcondor-ansible

# ── inventory.ini ──────────────────────────────────────────────────────────
cat > inventory.ini << 'EOF'
[head]
condor-head ansible_host=10.172.13.20

[workers]
condor-node01 ansible_host=10.172.13.21
condor-node02 ansible_host=10.172.13.22
condor-node03 ansible_host=10.172.13.23

[all:vars]
ansible_user=admin
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_become=true
ansible_become_method=sudo
EOF

# ── group_vars/all.yml ─────────────────────────────────────────────────────
cat > group_vars/all.yml << 'EOF'
condor_version: "23.x"
condor_manager_hostname: "condor-head"
condor_manager_ip: "10.172.13.20"
condor_port: 9618
condor_hosts:
  - { name: condor-head,   ip: "10.172.13.20" }
  - { name: condor-node01, ip: "10.172.13.21" }
  - { name: condor-node02, ip: "10.172.13.22" }
  - { name: condor-node03, ip: "10.172.13.23" }
condor_pool_password_file: /etc/condor/pool_password
condor_pool_password_tmp: /tmp/condor_pool_password_fetched
EOF

# ── group_vars/head.yml ────────────────────────────────────────────────────
cat > group_vars/head.yml << 'EOF'
condor_daemon_list: "MASTER, COLLECTOR, NEGOTIATOR, SCHEDD"
EOF

# ── group_vars/workers.yml ─────────────────────────────────────────────────
cat > group_vars/workers.yml << 'EOF'
condor_daemon_list: "MASTER, STARTD"
EOF

# ── templates/htcondor.repo.j2 ─────────────────────────────────────────────
cat > templates/htcondor.repo.j2 << 'EOF'
[htcondor-stable]
name=HTCondor Stable Repository (EL9)
baseurl=https://research.cs.wisc.edu/htcondor/repo/{{ condor_version }}/el9/release/
enabled=1
gpgcheck=1
gpgkey=https://research.cs.wisc.edu/htcondor/repo/{{ condor_version }}/el9/release/repodata/repomd.xml.key
repo_gpgcheck=0
EOF

# ── templates/condor_common.conf.j2 ───────────────────────────────────────
cat > templates/condor_common.conf.j2 << 'EOF'
CONDOR_HOST     = {{ condor_manager_hostname }}
COLLECTOR_HOST  = {{ condor_manager_hostname }}:{{ condor_port }}

SEC_DEFAULT_AUTHENTICATION          = REQUIRED
SEC_DEFAULT_INTEGRITY               = REQUIRED
SEC_DEFAULT_ENCRYPTION              = OPTIONAL
SEC_DEFAULT_AUTHENTICATION_METHODS  = FS, PASSWORD
SEC_CLIENT_AUTHENTICATION_METHODS   = FS, PASSWORD
SEC_PASSWORD_FILE                   = {{ condor_pool_password_file }}

ALLOW_WRITE = condor_pool@*/$(CONDOR_HOST), condor_pool@*
ALLOW_READ  = *

NETWORK_INTERFACE   = {{ ansible_default_ipv4.address }}
BIND_ALL_INTERFACES = FALSE

MAX_DEFAULT_LOG = 100Mb
MAX_NUM_LOG     = 2
EOF

# ── templates/condor_head.conf.j2 ─────────────────────────────────────────
cat > templates/condor_head.conf.j2 << 'EOF'
DAEMON_LIST = {{ condor_daemon_list }}

COLLECTOR_NAME = HTCondor Pool @ $(CONDOR_HOST)
COLLECTOR_LOG  = $(LOG)/CollectorLog

NEGOTIATOR_INTERVAL = 20
NEGOTIATOR_LOG      = $(LOG)/NegotiatorLog

SCHEDD_NAME      = $(FULL_HOSTNAME)
SCHEDD_LOG       = $(LOG)/SchedLog
MAX_JOBS_RUNNING = 10000
QUEUE_SUPER_USERS = root, condor

CONDOR_ADMIN = root@$(FULL_HOSTNAME)
EOF

# ── templates/condor_worker.conf.j2 ───────────────────────────────────────
cat > templates/condor_worker.conf.j2 << 'EOF'
DAEMON_LIST = {{ condor_daemon_list }}

NUM_SLOTS        = $(NUM_CPUS)
SLOT_TYPE_1      = cpus=1, mem=auto, disk=auto
NUM_SLOTS_TYPE_1 = $(NUM_CPUS)

START        = TRUE
SUSPEND      = FALSE
CONTINUE     = TRUE
PREEMPT      = FALSE
KILL         = FALSE
WANT_VACATE  = FALSE

STARTD_LOG  = $(LOG)/StartLog
STARTER_LOG = $(LOG)/StarterLog

SLOT1_EXECUTE = /tmp/condor/execute
EOF

# ── playbook.yml ───────────────────────────────────────────────────────────
cat > playbook.yml << 'EOF'
---
- name: HTCondor — Common Setup (all nodes)
  hosts: all
  become: true
  gather_facts: true
  tasks:

    - name: Populate /etc/hosts with all cluster nodes
      ansible.builtin.lineinfile:
        path: /etc/hosts
        regexp: "^{{ item.ip }}\\s"
        line: "{{ item.ip }}  {{ item.name }}"
        state: present
      loop: "{{ condor_hosts }}"

    - name: Install EPEL release
      ansible.builtin.dnf:
        name: epel-release
        state: present

    - name: Deploy HTCondor yum repository file
      ansible.builtin.template:
        src: templates/htcondor.repo.j2
        dest: /etc/yum.repos.d/htcondor.repo
        owner: root
        group: root
        mode: "0644"

    - name: Import HTCondor GPG key
      ansible.builtin.rpm_key:
        key: "https://research.cs.wisc.edu/htcondor/repo/{{ condor_version }}/el9/release/repodata/repomd.xml.key"
        state: present
      ignore_errors: true

    - name: Install HTCondor package
      ansible.builtin.dnf:
        name: condor
        state: present
        update_cache: true

    - name: Ensure condor group exists
      ansible.builtin.group:
        name: condor
        system: true
        state: present

    - name: Ensure condor user exists
      ansible.builtin.user:
        name: condor
        group: condor
        system: true
        shell: /sbin/nologin
        home: /var/lib/condor
        create_home: false
        state: present

    - name: Ensure /etc/condor/config.d exists
      ansible.builtin.file:
        path: /etc/condor/config.d
        state: directory
        owner: root
        group: condor
        mode: "0755"

    - name: Ensure execute directory exists on workers
      ansible.builtin.file:
        path: /tmp/condor/execute
        state: directory
        owner: condor
        group: condor
        mode: "0755"
      when: inventory_hostname in groups['workers']

    - name: Deploy common condor config
      ansible.builtin.template:
        src: templates/condor_common.conf.j2
        dest: /etc/condor/config.d/00_common.conf
        owner: root
        group: condor
        mode: "0644"
      notify: Restart condor

    - name: Check if firewalld is active
      ansible.builtin.systemd:
        name: firewalld
      register: firewalld_status
      ignore_errors: true

    - name: Open HTCondor port 9618/tcp in firewalld
      ansible.posix.firewall:
        port: "{{ condor_port }}/tcp"
        permanent: true
        state: enabled
        immediate: true
      when:
        - firewalld_status is defined
        - firewalld_status.status is defined
        - firewalld_status.status.ActiveState == "active"
      ignore_errors: true

  handlers:
    - name: Restart condor
      ansible.builtin.service:
        name: condor
        state: restarted

- name: HTCondor — Configure Head Node
  hosts: head
  become: true
  gather_facts: true
  tasks:

    - name: Deploy head node condor config
      ansible.builtin.template:
        src: templates/condor_head.conf.j2
        dest: /etc/condor/config.d/10_head.conf
        owner: root
        group: condor
        mode: "0644"
      notify: Restart condor

    - name: Check if pool password already exists
      ansible.builtin.stat:
        path: "{{ condor_pool_password_file }}"
      register: pool_pw_stat

    - name: Generate pool password
      ansible.builtin.shell:
        cmd: "openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32 > {{ condor_pool_password_file }}"
      when: not pool_pw_stat.stat.exists
      args:
        creates: "{{ condor_pool_password_file }}"

    - name: Set correct permissions on pool password file
      ansible.builtin.file:
        path: "{{ condor_pool_password_file }}"
        owner: root
        group: condor
        mode: "0640"

    - name: Fetch pool password to controller
      ansible.builtin.fetch:
        src: "{{ condor_pool_password_file }}"
        dest: "{{ condor_pool_password_tmp }}"
        flat: true

    - name: Enable and start condor on head node
      ansible.builtin.service:
        name: condor
        enabled: true
        state: started

  handlers:
    - name: Restart condor
      ansible.builtin.service:
        name: condor
        state: restarted

- name: HTCondor — Configure Worker Nodes
  hosts: workers
  become: true
  gather_facts: true
  tasks:

    - name: Deploy worker node condor config
      ansible.builtin.template:
        src: templates/condor_worker.conf.j2
        dest: /etc/condor/config.d/10_worker.conf
        owner: root
        group: condor
        mode: "0644"
      notify: Restart condor

    - name: Copy pool password to worker nodes
      ansible.builtin.copy:
        src: "{{ condor_pool_password_tmp }}"
        dest: "{{ condor_pool_password_file }}"
        owner: root
        group: condor
        mode: "0640"
      notify: Restart condor

    - name: Enable and start condor on worker nodes
      ansible.builtin.service:
        name: condor
        enabled: true
        state: started

  handlers:
    - name: Restart condor
      ansible.builtin.service:
        name: condor
        state: restarted
EOF

# ── test_job/sleep.sub ─────────────────────────────────────────────────────
cat > test_job/sleep.sub << 'EOF'
universe       = vanilla
executable     = /bin/sleep
arguments      = 30
log            = sleep_test.log
output         = sleep_test_$(Process).out
error          = sleep_test_$(Process).err
request_cpus   = 1
request_memory = 128MB
request_disk   = 100MB
queue 3
EOF

echo "Done. Verifying..."
find . -type f | sort
