# cheese-on-prem

This is a public repository for installing the CHEESE on-premises version.

### Requirements

- Ubuntu

- Docker

### Installing CHEESE

You can install CHEESE on your instance using the following steps :

1. Clone this repository on your instance

2. Make an environment file by copying the template environment configuration file in `config/cheese-env.conf.template` which defines global environment variables, and modify it accordingly.

    - `CHEESE_CUSTOMER` : The customer name
    - `CHEESE_PASSWORD` : The password used to pull Docker images for running CHEESE

Please contact us for providing the customer name and password.

    - `CHEESE_LICENSE_FILE` : The CHEESE license file
    - `CONFIG_FILE` : A YAML configuration file for running the CHEESE tool on-premises which contains paths to your search databases,models... A template can be found in `config/cheese_config_file.yaml.template`
    - `VISUALISATION_MODELS_PATH` : The path to the CHEESE embedding visualization models.

Please make sure that you only provide absolute file path in the `.conf` file.

3. Download the CHEESE visualisation models `.zip` file (please contact us for providing the access), <b>unzip</b> it and put all the files (`*.pca` and `*.umap`) in some folder of your choice. Set up the environment variable `VISUALISATION_MODELS_PATH` of your `cheese-env.conf` config file to the same path as well.


4. If needed, modify your `~/.bashrc` file and append the following script at the end of it :

```
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
```
and run `source ~/.bashrc`

5. Run `bash install-cheese.sh --env_file <env_config_file>`. Where `<env_config_file>` is the path to your environment configuration file.

6. Check if CHEESE is installed by running `cheese`

7. Test if the installation is working by running the command `cheese test` 


### CHEESE on-prem Docs
To use CHEESE on-prem version, please consult our [CHEESE Docs page](https://cheese-docs.deepmedchem.com/on-prem-showcase/)
