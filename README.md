🛡️ Vibe-Stack Pro: Fortress Edition

**Vibe-Stack Pro** is a high-performance, secure-by-default LEMP stack provisioning script specifically designed for **AlmaLinux 9**. It automates the complex parts of server management—firewalls, user isolation, multi-PHP pools, and SSH security—allowing you to deploy a production-ready environment in seconds.

---

🚀 Core Features

* **Nginx + MariaDB + Multi-PHP:** Leverages Remi's repository for the latest stable PHP versions (8.1 through 8.5).
* **Fortress-Grade Isolation:** Uses standard Linux permissions (`750`) and PHP `open_basedir` to ensure users cannot snoop on other sites.
* **CSF Firewall Integration:** Pre-configured ConfigServer Security & Firewall with LXD container support and high-risk blocklists.
* **Automated SSH Management:** Generates unique **ED25519** key pairs for every site and installs them automatically.
* **Secure-by-Default:** Global HTTP-to-HTTPS redirection with an ACME bypass for easy Let's Encrypt (Certbot) renewals.
* **Performance Tuning:** Includes FastCGI buffering, `pm = ondemand` process management, and automated log rotation.

---

🛠️ Installation & Setup

1. Initial Server Setup

On a fresh AlmaLinux 9 install, run the setup command to install the base dependencies, configure the global Nginx settings, and arm the CSF firewall.

chmod +x vibestack.sh
./vibestack.sh setup

### 2. Adding a New Site

Provision a new site with a specific PHP version. This command creates the user, the directory structure, the database, the PHP pool, and the SSH keys.

./vibestack.sh example.com 8.4

### 3. Removing a Site

Purge all traces of a site, including its database, user files, logs, and configuration.

./vibestack.sh remove example.com

---

📂 Directory Structure

Vibe-Stack follows a clean, predictable directory structure inspired by industry standards:

| Path | Description |
| --- | --- |
| `/home/nginx/domains/domain.com/public` | The web root for your site files. |
| `/home/nginx/domains/domain.com/logs` | Access and Error logs (automated rotation). |
| `/home/nginx/domains/domain.com/.ssh` | Contains the ED25519 private/public keys. |
| `/home/nginx/domains/domain.com/ssl` | Self-signed placeholder certificates. |
| `/etc/nginx/conf.d/domain.com.conf` | Nginx vhost configuration. |

---

🔒 Security Philosophy

Vibe-Stack Pro doesn't rely on complex jailing mechanisms that break application functionality. Instead, it uses **layered security**:

1. **Network Layer:** CSF Firewall blocks everything except essential ports (22, 2222, 80, 443).
2. **Filesystem Layer:** Web roots are locked to `750`. Only the owner and the `nginx` group can enter.
3. **Application Layer:** `open_basedir` prevents PHP from executing or reading files outside the site's own directory.
4. **Identity Layer:** Password authentication is discouraged; ED25519 keys are generated and assigned by default.

---

📜 License

This project is open-source. Feel free to fork, modify, and vibe.
