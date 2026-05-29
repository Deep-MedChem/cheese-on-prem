# cheese-on-prem

This is a public repository for installing the CHEESE on-premises version.

### Requirements

- Ubuntu
- git
- Docker
The unix user must be a member of the group `docker` (check by running `docker ps`.)

## Installing CHEESE

You can install CHEESE on your instance using the following steps :

1. Clone this repository on your instance

2. Install CHEESE CLI by running `bash install-cheese.sh` in the repo's directory. Then re-log in to the shell (or run `source ~/.bashrc`) and check if the installation completed by running `cheese`

3. Contact us to provide you with a `CHEESE_PASSWORD` to be able to download CHEESE docker images.

4. Run `cheese update-env` and insert the `CHEESE_PASSWORD` in the config file

5. Run `cheese update-images` to be able to download the docker images. This step will take a while!

6. After `cheese-database` image is successfully pulled, run `cheese generate-license-key` to generate your license key.

7. Send us the key so that we can generate your license file.

8. Once we send you the JSON license file, run `cheese update-license` and paste its contents there

9. You can now use CHEESE on-prem version.

## Adding the databases

By default, Cheese comes with a small test database which can be used to test the general workflow. 

To download real databases, run 
1. `cheese configure-dbs`

Will fetch the list of available databases from the CHEESE SFTP server. 



## Running CHEESE

- To start the CHEESE instance, run `cheese start`. 
> This starts a docker network of about 7 docker images. The startup takes a few minutes. 


## Housekeeping

### Updating databases
`cheese update-dbs`

COMING SOON