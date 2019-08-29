#!/bin/bash

while getopts ":p:r:u:c:" arg; do
    case "${arg}" in
      p)
        package_location=${OPTARG}
        ;;
      r)
        registry=${OPTARG}
        ;;
      u)
        reguser=${OPTARG}
        ;;  
      c)
        regpassword=${OPTARG}
        ;;
    esac
done

echo "package_location=${package_location}"
echo "registry=${registry}"
echo "reguser=${reguser}"

if [ -z "${package_location}" ]; then

 echo " no image file, do nothing"
  exit 0
fi

basenamef=$(basename ${package_location})
echo "basenamef=$basenamef"

if [ -f /opt/ibm/cluster/images/$basenamef ]; then
 	echo "image file seems to have been already loaded to /opt/ibm/cluster/images/$basenamef, do nothing"
  exit 0

fi

image_file="/tmp/$(basename ${package_location})"
echo "image_file=$image_file"

sourcedir="/tmp/icpimages"
# Get package from remote location if needed
if [[ "${package_location:0:4}" == "http" ]]; then

  # Extract filename from URL if possible
  if [[ "${package_location: -2}" == "gz" ]]; then
    # Assume a sensible filename can be extracted from URL
    filename=$(basename ${package_location})
  else
    # TODO We'll need to attempt some magic to extract the filename
    echo "Not able to determine filename from URL ${package_location}" >&2
    exit 1
  fi

  # Download the file using auth if provided
  echo "Downloading ${package_location}" >&2
  mkdir -p ${sourcedir}
  wget --continue ${username:+--user} ${username} ${password:+--password} ${password} \
   -O ${sourcedir}/${filename} "${package_location}"

  # Set the image file name if we're on the same platform
  if [[ ${filename} =~ .*$(uname -m).* ]]; then
    echo "Setting image_file to ${sourcedir}/${filename}"
    image_file="${sourcedir}/${filename}"
  fi
elif [[ "${package_location:0:3}" == "nfs" ]]; then
  # Separate out the filename and path
  sourcedir="/opt/ibm/cluster/images"
  nfs_mount=$(dirname ${package_location:4})
  image_file="${sourcedir}/$(basename ${package_location})"
  sudo mkdir -p ${sourcedir}

  # Mount
  sudo mount.nfs $nfs_mount $sourcedir
  if [ $? -ne 0 ]; then
    echo "An error occurred mounting the NFS server. Mount point: $nfs_mount"
    exit 1
  fi

else
  # This must be uploaded from local file, terraform should have copied it to /tmp
  image_file="/tmp/$(basename ${package_location})"

fi

echo "Unpacking ${image_file} ..."
pv --interval 10 ${image_file} | tar zxf - -O | sudo docker load


if [ -z "${registry}" ]; then

	sudo mkdir -p /opt/ibm/cluster/images
	sudo mv ${image_file} /opt/ibm/cluster/images/
	
	sudo chown $(whoami) -R /opt/ibm/cluster/images

 echo " no private registry setup exit now"
  exit 0
fi

# find my private IP address, which will be on the interface the default route is configured on
myip=`ip route get 10.0.0.11 | awk 'NR==1 {print $NF}'`

echo "${myip} ${registry}" | sudo tee -a /etc/hosts

sudo mkdir -p /registry
sudo mkdir -p /etc/docker/certs.d/${registry}
sudo cp /etc/registry/registry-cert.pem /etc/docker/certs.d/${registry}/ca.crt

# Create authentication
sudo mkdir /auth
sudo docker run \
  --entrypoint htpasswd \
  registry:2 -Bbn ${reguser} ${regpassword} | sudo tee /auth/htpasswd

sudo docker run -d \
  --restart=always \
  --name registry \
  -v /etc/registry:/certs \
  -v /registry:/registry \
  -v /auth:/auth \
  -e "REGISTRY_AUTH=htpasswd" \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/registry \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:8500 \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry-cert.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry-key.pem  \
  -p 8500:8500 \
  registry:2

# Retag images for private registry
sudo docker images | grep -v REPOSITORY | grep -v ${registry} | awk '{print $1 ":" $2}' | xargs -n1 -I{} sudo docker tag {} ${registry}:8500/{}

# ICP 3.1.0 archives also includes the architecture in image names which is not expected in private repos, also tag a non-arched version
sudo docker images | grep ${registry}:8500 | grep "amd64" | awk '{gsub("-amd64", "") ; print $1 "-amd64:" $2 " " $1 ":" $2 }' | xargs -n2  sh -c 'sudo docker tag $1 $2' argv0

# Push all images and tags to private docker registry
if sudo docker login --password ${regpassword} --username ${reguser} ${registry}:8500 ; then
    echo "docker login success"
else
   echo "docker login failed"
   exit 1
fi 

while read image; do
  echo "Pushing ${image}"
  sudo docker push ${image} >> /tmp/imagepush.log
done < <(sudo docker images | grep ${registry} | awk '{print $1 ":" $2}' | sort | uniq)

sudo mkdir -p /opt/ibm/cluster/images
sudo mv ${image_file} /opt/ibm/cluster/images/

sudo chown $(whoami) -R /opt/ibm/cluster/images

