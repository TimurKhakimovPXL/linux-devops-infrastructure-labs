> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

**Types of UBI-images**
	1) UBI Standard
	2) UBI Minimal
	3) UBI Micro
	4) UBI Init

**UBI Standard**

```bash

- Default "general purpose" image 
  --> Strikes a balance between size and functionality
Key Features:
- Includes the full yum/dnf package manager


-------------------------------------------------------------------
Installing Python on the smallest possible image is not directly possible due to the nature of the image (lacks package manager)

We can however use a %ulti-Stage build



https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/building_running_and_managing_containers/assembly_adding-software-to-a-ubi-container_building-running-and-managing-containers#proc_using-the-ubi-micro-images_assembly_adding-software-to-a-ubi-container