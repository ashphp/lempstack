# LEMP Stack Auto Installer
- Interactive LEMP stack installer on Almalinux 8/9/10
- Installs Nginx, MariaDB and PHP 8.4 on AlmaLinux
- Optional WordPress + (Memcached or Redis) installation.
- Auto SSL installation with Certbot and Let's Encrypt with fallback to self-signed cert. if domain validation failed or if no domain/hostname is used (Server IP address is used).


# Installation
- Run the following command as root and follow the prompts

```
cd /root/ && wget https://raw.githubusercontent.com/ashphp/lempstack/refs/heads/main/install.sh -O install_lemp.sh && chmod +x install_lemp.sh && ./install_lemp.sh
```
- If the SSL certificate installation failed at the time of installation, after you point the domain/hostname to the server IP, you can run this command to reissue the cert.
 ```
 certbot --nginx -d yourdomain.com -m admin@yourdomain.com --agree-tos --redirect
 ```

> [!IMPORTANT]
>`redis` cache option is not available in Almalinux 10 (when WP installation is selected).

### 🤖 This code is `AI` generated.
