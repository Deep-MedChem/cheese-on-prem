# CHEESE platform on-premises 

![cheese.png](assets/cheese.png)

Full CHEESE platform on-premises version.

### Requirements

- A physical or virtual machine with Ubuntu 24.
- git
- Docker; the unix user must be a member of the `docker` group (check by running `docker ps`).

## Installing CHEESE

### 1. CHEESE CLI

You can install CHEESE on your instance using the following steps :

1. Clone this repository 

```bash
git@github.com:Deep-MedChem/cheese-on-prem.git
```

2. Install CHEESE CLI: 

```bash
bash install-cheese.sh
``` 
in the repo's directory. Follow the prompts. Then re-log in to the shell (or run `source ~/.bashrc`) and check if the installation completed by running `cheese`

3. Contact us to provide you with a `CHEESE_PASSWORD` to be able to download CHEESE docker images.

4. Run `cheese update-env` and insert the `CHEESE_PASSWORD` in the config file

5. Run `cheese update-images` to be able to download the docker images. _This step will take a while!_

6. After `cheese-database` image is successfully pulled, run `cheese generate-license-key` to generate your license key.

7. Send us the key so that we can generate your license file.

8. Once we send you the JSON license file, run `cheese update-license` and paste its contents there.

9. You can now use CHEESE on-prem version. Start the platform by running `cheese start`
> This starts a docker network of about 7 docker images. The startup takes a few minutes. 

### 2. CHEESE databases

By default, Cheese comes with a small test database which can be used to test the general workflow. 

Database download happens in two steps:

1. `cheese configure-dbs`

Will fetch the list of available databases from the CHEESE SFTP server. 

2. fetches the selected databases and auto-register them in the engine config: 

```bash
cheese download-dbs --dest <folder>
```
For how the engine recognizes a
database (the required folder structure and the `OUTPUT_DIRECTORIES` /
`INDEX_TYPES` / `DELIMITERS` config entries), and how to fix a DB that won't
load, see [docs/database-configuration.md](docs/database-configuration.md).


## Housekeeping

Available cheese commands:

### Updating CHEESE

Currently, there is no support for automatic updates (COMING SOON!). 
When we notify you that the update is necessary, please run:
```bash
cheese update-scripts    # Pulls the latest scripts from this repo
cheese update-images     # Pulls the latest images from DeepMedChem container registry.
```

### Updating databases

```bash
cheese update-dbs
```

### Troubleshooting

```bash
cheese doctor
```