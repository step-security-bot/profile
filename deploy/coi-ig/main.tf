# Создание сервисного аккаунта для группы ВМ
resource "yandex_iam_service_account" "ig-sa" {
  name        = "ig-sa"
  description = "Сервисный аккаунт для управления группой ВМ."
}

resource "yandex_resourcemanager_folder_iam_member" "vm-autoscale-sa-role-image-puller" {
  folder_id = var.folder_id
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.ig-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "vm-autoscale-sa-role-compute" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.ig-sa.id}"
  depends_on = [
    yandex_iam_service_account.ig-sa,
  ]
}

# Создание облачной сети
resource "yandex_vpc_network" "network" {
  name = "vm-network"
}

resource "yandex_vpc_subnet" "subnet-1" {
  name           = "subnet-1"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.1.0/24"]
}

# Создание статического публичного IP-адреса
resource "yandex_vpc_address" "stat_address" {
  name = "alb-static-address"
  external_ipv4_address {
    zone_id = "ru-central1-a"
  }
}

# Создание групп безопасности
resource "yandex_vpc_security_group" "alb-sg" {
  name       = "alb-sg"
  network_id = yandex_vpc_network.network.id

  egress {
    protocol       = "ANY"
    description    = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 1
    to_port        = 65535
  }

  ingress {
    protocol       = "TCP"
    description    = "ext-http"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    description    = "ext-https"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  ingress {
    protocol          = "TCP"
    description       = "healthchecks"
    predefined_target = "loadbalancer_healthchecks"
    port              = 30080
  }
}

resource "yandex_vpc_security_group" "alb-vm-sg" {
  name       = "alb-vm-sg"
  network_id = yandex_vpc_network.network.id

  ingress {
    protocol          = "TCP"
    description       = "balancer"
    security_group_id = yandex_vpc_security_group.alb-sg.id
    port              = 3000
  }

  ingress {
    protocol       = "TCP"
    description    = "ssh"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }
}

# Создание группы ВМ
data "yandex_compute_image" "container-optimized-image" {
  family = "container-optimized-image"
}

resource "yandex_compute_instance_group" "ig-with-coi" {
  service_account_id  = yandex_iam_service_account.ig-sa.id
  deletion_protection = true
  instance_template {
    service_account_id = yandex_iam_service_account.ig-sa.id
    platform_id        = "standard-v3"
    resources {
      memory = 2
      cores  = 2
    }
    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.container-optimized-image.id
      }
    }
    network_interface {
      network_id = yandex_vpc_network.network.id
      subnet_ids = [
        yandex_vpc_subnet.subnet-1.id,
      ]
      security_group_ids = [yandex_vpc_security_group.alb-vm-sg.id]
      nat                = true
    }
    metadata = {
      docker-container-declaration = templatefile("${path.module}/declaration.yaml", { image_url = var.image_url })
      user-data                    = templatefile("${path.module}/cloud_config.yaml", { user = var.vm_user, ssh_key = var.ssh_key })
    }
  }
  scale_policy {
    fixed_scale {
      size = 1
    }
  }
  allocation_policy {
    zones = ["ru-central1-a"]
  }
  deploy_policy {
    max_unavailable = 1
    max_creating    = 1
    max_expansion   = 1
    max_deleting    = 1
    strategy        = "opportunistic"
  }
  application_load_balancer {
    target_group_name = "alb-tg"
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.vm-autoscale-sa-role-compute]
}

# Создание группы бэкендов
resource "yandex_alb_backend_group" "alb-bg" {
  name = "alb-bg"

  http_backend {
    name             = "backend-1"
    port             = 3000
    target_group_ids = [yandex_compute_instance_group.ig-with-coi.application_load_balancer.0.target_group_id]
    healthcheck {
      timeout  = "1s"
      interval = "2s"
      http_healthcheck {
        path = "/api/health"
      }
    }
  }
}

# Создание HTTP-роутера
resource "yandex_alb_http_router" "alb-router" {
  name = "alb-router"
}

resource "yandex_alb_virtual_host" "alb-host" {
  name           = "alb-host"
  http_router_id = yandex_alb_http_router.alb-router.id
  authority      = [var.domain, "www.${var.domain}"]
  route {
    name = "route-1"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.alb-bg.id
      }
    }
  }
}

# Создание L7-балансировщика
resource "yandex_alb_load_balancer" "alb" {
  name               = "alb-1"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.alb-sg.id]

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.subnet-1.id
    }
  }

  listener {
    name = "http-listener"
    endpoint {
      address {
        external_ipv4_address {
          address = yandex_vpc_address.stat_address.external_ipv4_address[0].address
        }
      }
      ports = [80]
    }
    http {
      redirects {
        http_to_https = true
      }
    }
  }

  listener {
    name = "https-listener"
    endpoint {
      address {
        external_ipv4_address {
          address = yandex_vpc_address.stat_address.external_ipv4_address[0].address
        }
      }
      ports = [443]
    }
    tls {
      default_handler {
        http_handler {
          http_router_id = yandex_alb_http_router.alb-router.id
        }
        certificate_ids = [data.yandex_cm_certificate.cm_certificate.id]
      }
      sni_handler {
        name         = "sni-handler"
        server_names = ["${var.domain}"]
        handler {
          http_handler {
            http_router_id = yandex_alb_http_router.alb-router.id
          }
          certificate_ids = [data.yandex_cm_certificate.cm_certificate.id]
        }
      }
    }
  }
}


# TLS-сертификат сайта
resource "yandex_cm_certificate" "cm_certificate" {
  name    = "cm-certificate"
  domains = [var.domain, "*.${var.domain}"]

  managed {
    challenge_type  = "DNS_CNAME"
    challenge_count = 1
  }
}

# Создание DNS-зоны
resource "yandex_dns_zone" "alb-zone" {
  name        = "alb-zone"
  description = "Public zone"
  zone        = "${var.domain}."
  public      = true
}

# Создание ресурсной записи в DNS-зоне
resource "yandex_dns_recordset" "alb-record" {
  zone_id = yandex_dns_zone.alb-zone.id
  name    = "${var.domain}."
  ttl     = 600
  type    = "A"
  data    = [yandex_alb_load_balancer.alb.listener[0].endpoint[0].address[0].external_ipv4_address[0].address]
}

resource "yandex_dns_recordset" "challenge" {
  count   = yandex_cm_certificate.cm_certificate.managed[0].challenge_count
  zone_id = yandex_dns_zone.alb-zone.id
  name    = yandex_cm_certificate.cm_certificate.challenges[count.index].dns_name
  type    = yandex_cm_certificate.cm_certificate.challenges[count.index].dns_type
  data    = [yandex_cm_certificate.cm_certificate.challenges[count.index].dns_value]
  ttl     = 600
}

data "yandex_cm_certificate" "cm_certificate" {
  depends_on      = [yandex_dns_recordset.challenge]
  certificate_id  = yandex_cm_certificate.cm_certificate.id
  wait_validation = true
}