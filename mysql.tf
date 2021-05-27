terraform {
  required_version = ">= 0.14.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.26"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "mysql-rg" {
    name     = "rg"
    location = "West Europe"   
}

resource "azurerm_virtual_network" "mysql-vn" {
    name                = "vn"
    address_space       = ["10.80.0.0/16"]
    location            = azurerm_resource_group.mysql-rg.location
    resource_group_name = azurerm_resource_group.mysql-rg.name
}

resource "azurerm_subnet" "mysql-subnet" {
    name                 = "subnet"
    resource_group_name  = azurerm_resource_group.mysql-rg.name
    virtual_network_name = azurerm_virtual_network.mysql-vn.name
    address_prefixes       = ["10.80.4.0/24"]
}

resource "azurerm_public_ip" "mysql-publicip" {
    name                         = "publicip"
    location                     = azurerm_resource_group.mysql-rg.location
    resource_group_name          = azurerm_resource_group.mysql-rg.name
    allocation_method            = "Static"
}

resource "azurerm_network_security_group" "mysql-nsg" {
    name                = "nsg"
    location            = azurerm_resource_group.mysql-rg.location
    resource_group_name = azurerm_resource_group.rgmysqlteste.name

    security_rule {
        name                       = "mysql"
        priority                   = 1000
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "SSH"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface" "mysql-nic" {
    name                      = "nic"
    location                  = azurerm_resource_group.mysql-rg.location
    resource_group_name       = azurerm_resource_group.mysql-rg.name

    ip_configuration {
        name                          = "nicConfiguration"
        subnet_id                     = azurerm_subnet.mysql-subnet.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.mysql-publicip.id
    }
}

resource "azurerm_network_interface_security_group_association" "mysql-nisg" {
    network_interface_id      = azurerm_network_interface.mysql-nic.id
    network_security_group_id = azurerm_network_security_group.mysql-nsg.id
}

data "azurerm_public_ip" "mysql-data-publicip" {
  name                = azurerm_public_ip.mysql-publicip.name
  resource_group_name = azurerm_resource_group.mysql-rg.name
}

resource "azurerm_storage_account" "mysql-sa" {
    name                        = "storageaccount"
    resource_group_name         = azurerm_resource_group.mysql-rg.name
    location                    = azurerm_resource_group.mysql-rg.location
    account_tier                = "Standard"
    account_replication_type    = "LRS"
}

resource "azurerm_linux_virtual_machine" "mysql-vm" {
    name                  = "vm"
    location              = azurerm_resource_group.mysql-rg.location
    resource_group_name   = azurerm_resource_group.mysql-rg.name
    network_interface_ids = [azurerm_network_interface.mysql-nic.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "osDiskMySQL"
        caching           = "ReadWrite"
        storage_account_type = "Standard_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "mySqlvm"
    admin_username = var.user
    admin_password = var.password
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.samsqlteste.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.mysql-rg ]
}

output "public_ip_address_mysql" {
  value = azurerm_public_ip.mysql-publicip.ip_address
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.mysql-vm]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.mysql-data-publicip.ip_address
        }
        source = "mysql/script"
        destination = "/home/azureuser"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.mysql-data-publicip.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/azureuser/config/user.sql",
            "sudo cp -f /home/azureuser/config/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}