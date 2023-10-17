# Azure-ARM

ARM Templates for Nerdio Private Deployment

:cloud: - [Introduction](#introduction) - [Design](#design) - [Deployment](#deployment) - [Requirements](#requirements-and-limitations) - [Configuration](#configuration) - :cloud:

## Introduction

## Design

The Azure ARM Template will deploy the following resources:

- 1 Virtual Network with 2 Subnets
- 1 Azure App Service Plan
- 1 Azure App Service
- 1 Azure SQL Server
- 1 Azure SQL Database
- 1 Key Vault
- 1 Public IP Address
- 1 NAT Gateway
- 6 Private Endpoints (1 Per Service)
- 6 Network Interfaces (1 Per Private Endpoint)
- 9 Private DNS Zones
- 1 Azure Monitor Private Link Scope
- 2 Log Analytic Workspaces
- 1 Azure Monitor Application Insights
- 1 Azure Monitor Smart Detector Rule
- 1 Azure Monitor Action Group
- 2 Automation accounts
- 1 Runbook

![nerdio private deployment design](images/nerdio-private.png)

## Deployment

### Azure Portal

Standard Custom Template Deployment:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fswansosj%2FAzure-ARM%2Fmain%2FAVD%2FNerdio-Private%2Fazuredeploy.json)

## Requirements-and-limitations

## Configuration
