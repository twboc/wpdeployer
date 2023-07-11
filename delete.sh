
read -p "DO YOU WANT TO DELETE DOMAINS AND VOLUMES? " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]
then
    rm -rf volumes/*
    rm -rf domains/*    
fi
