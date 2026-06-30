terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "trading-bot"
    storage_account_name = "tradingbottfstate"
    container_name       = "tfstate"
    key                  = "trading-bot.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralindia"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "trading-bot"
}

variable "acr_password" {
  description = "ACR admin password"
  type        = string
  sensitive   = true
}

variable "kite_api_key" {
  description = "Kite API Key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "kite_api_secret" {
  description = "Kite API Secret"
  type        = string
  sensitive   = true
  default     = ""
}

data "azurerm_client_config" "current" {}

# ── Resource Group ──
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# ── App Service Plan ──
resource "azurerm_service_plan" "plan" {
  name                = "trading-bot-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# ── Key Vault ──
resource "azurerm_key_vault" "kv" {
  name                       = "trading-bot-kv-sk"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 90
  purge_protection_enabled   = false
}

# ── Container Registry ──
resource "azurerm_container_registry" "acr" {
  name                = "tradingbotkiteacr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# ── Web App ──
resource "azurerm_linux_web_app" "webapp" {
  name                = "trading-bot-kite"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      node_version = "22-lts"
    }
    always_on = false
  }

  app_settings = {
    "AZURE_KEYVAULT_NAME"    = azurerm_key_vault.kv.name
    "AZURE_SUBSCRIPTION_ID"  = var.subscription_id
    "AZURE_RESOURCE_GROUP"   = azurerm_resource_group.rg.name
    "ACR_LOGIN_SERVER"       = azurerm_container_registry.acr.login_server
    "ACR_USERNAME"           = azurerm_container_registry.acr.admin_username
    "ACR_PASSWORD"           = var.acr_password
    "WEBSITES_PORT"          = "8080"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
  }
}

# ── RBAC: WebApp -> Key Vault Secrets Officer ──
resource "azurerm_role_assignment" "webapp_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_web_app.webapp.identity[0].principal_id
}

# ── RBAC: WebApp -> Contributor on RG (for ACI creation) ──
resource "azurerm_role_assignment" "webapp_contributor" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_web_app.webapp.identity[0].principal_id
}

# ── Outputs ──
output "webapp_url" {
  value = "https://${azurerm_linux_web_app.webapp.default_hostname}"
}

output "webapp_name" {
  value = azurerm_linux_web_app.webapp.name
}

output "keyvault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}
