
docker ps

echo Provide container id:
read container_id


sudo docker stop $container_id
sudo docker rm -f $container_id