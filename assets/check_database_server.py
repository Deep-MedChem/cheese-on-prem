import requests
import requests
import argparse
import sys
import subprocess
import time

parser = argparse.ArgumentParser()

parser.add_argument('--ip', type=str, help='IP address')
parser.add_argument('--db_port', type=str, help='PORT of the API')
parser.add_argument('--container_name', type=str, help='The user')
args = parser.parse_args()





success=False
db_container_state=True

docker_state_flag='{{.State.Running}}'

t1=time.time()

try:
    while ((not success) and db_container_state):
        if time.time()-t1>(5): # timeout 5 minutes:
            print("Can't connect to database server. Timeout after 5 minutes !!!")
            sys.exit(1)

        try:
            state=subprocess.check_output(f"""docker container inspect -f {docker_state_flag} {args.container_name}""", shell=True)
        except subprocess.CalledProcessError as e:
            print("Database server is down !!!")
            sys.exit(0)


        db_container_state = state.decode("utf-8").strip()=="true"
        try:
            resp=requests.get(f'http://{args.ip}:{args.db_port}/test',{},verify=False).json()
            success=True
            print("Connected to database server !")
        except:
            if not db_container_state:
                print("Database server is down !!!")
                sys.exit(0)
            continue

except KeyboardInterrupt:
    sys.exit(1)