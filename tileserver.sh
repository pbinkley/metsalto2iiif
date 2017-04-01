#!/bin/bash
sudo docker run -v /home/pbinkley/Projects/iiif/metsalto2iiif/data/LAA/1907050201:/data -ti --rm -p 80:80 klokantech/iiifserver-iipimage-jpeg2000
