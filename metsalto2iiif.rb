#!/usr/bin/env ruby

require 'nokogiri'
require 'json'
require 'pry'
#require 'fastimage'

path = "data/LAA/1907050201"

mets = Nokogiri::XML(File.open(path + "/1907050201.xml")).xpath("/xmlns:mets")
structMap = mets.xpath("xmlns:structMap")
fileSec = mets.xpath("xmlns:fileSec")
mods = mets.xpath("xmlns:dmdSec/xmlns:mdWrap/xmlns:xmlData/mods:mods")
date = mods.xpath("mods:originInfo/mods:dateIssued").text

articles = Nokogiri::XML(File.open(path + "/articles_1907050201.xml")).xpath("/xmlns:mets")
logicalmap = articles.xpath("xmlns:structMap[@TYPE='LOGICAL']/xmlns:div[@TYPE='Issue']")

id = "http://localhost:8080"
# could add path: "/LAA/" + date.gsub("-", "/")
#imageservice = "http://example.org/images"
imageservice = "http://127.0.0.1:8081"

ocrfiles = fileSec.xpath("xmlns:fileGrp/xmlns:file[@USE='ocr']")
servicefiles = fileSec.xpath("xmlns:fileGrp/xmlns:file[@USE='service']")

iiif_presentation_context = "http://iiif.io/api/presentation/2/context.json"
iiif_image_context = "http://iiif.io/api/image/2/context.json"
iiif_profile = "http://iiif.io/api/image/2/profiles/level2.json"

obj = {
	"@id" => id + "/manifest",
	"@context" => iiif_presentation_context,
	"@type" => "sc:Manifest",
	"navDate" => date + "T00:00:00Z"
}
obj["label"] = "The Advertiser (Lacombe), 2 May 1907"
obj["metadata"] = [
	{"label" => "Publication", "value" => "The Advertise and Central Alberta News"}
]

sequence = {
	"@context" => iiif_presentation_context,
	"@id" => id + "/sequence/normal",
	"@type" => "sc:Sequence",
	"label" => "Current Page Order",
	"viewingDirection" => "left-to-right",
	"viewingHint" => "paged",
	"startCanvas": id + "/canvas/p1"
}

canvases = []
structures = []
pagealtos = {}

mets.xpath("xmlns:dmdSec[xmlns:mdWrap/@LABEL='Page metadata']").each { |page|
	pageid = page.xpath("@ID").text # e.g. pageModsBib1
	pagenum = page.xpath("xmlns:mdWrap/xmlns:xmlData/mods:mods/mods:part/mods:extent/mods:start").text

	# get entry in structMap
	structMapEntry = structMap.xpath("xmlns:div/xmlns:div[@DMDID=$pageid]", nil, {:pageid => pageid})

# structMapEntry: 
=begin
<div TYPE="np:page" DMDID="pageModsBib7">
    <fptr FILEID="masterFile7"/>
    <fptr FILEID="serviceFile7"/>
    <fptr FILEID="otherDerivativeFile7"/>
    <fptr FILEID="ocrFile7"/>
</div>

fileGrp:

<fileGrp ID="pageFileGrp8">
    <file ID="masterFile8" USE="master" >               
        <FLocat LOCTYPE="OTHER" OTHERLOCTYPE="file" xlink:href="0007.tif" />                                    
    </file>
    <file ID="serviceFile8" USE="service" >               
        <FLocat LOCTYPE="OTHER" OTHERLOCTYPE="file" xlink:href="0007.jp2" />                                                
    </file>
    <file ID="otherDerivativeFile8" USE="derivative" >               
        <FLocat LOCTYPE="OTHER" OTHERLOCTYPE="file" xlink:href="0007.pdf" />                                                
    </file>            
    <file ID="ocrFile8" USE="ocr" >               
        <FLocat LOCTYPE="OTHER" OTHERLOCTYPE="file" xlink:href="0007.xml" />                                                
    </file>                       
</fileGrp>

so: $structMapEntry/div/fptr/@FILEID = $filegrp/file/@ID
but the left side is a nodeset with four members
=end

	fileptrs = structMapEntry.xpath("xmlns:fptr")

	# find a fileptr whose @ID matches the @FILEID of one of the ocrfiles
	matches = nil
	fileptrs.xpath("@FILEID").each { |fp|
		matches = ocrfiles.filter("*[@ID = '" + fp.text + "']")
		break if matches.size > 0
	}
	ocrfilename = matches[0].xpath("./xmlns:FLocat/@xlink:href").text

	# find the jp2 i.e. the "service" file
	matches = nil
	fileptrs.xpath("@FILEID").each { |fp|
		matches = servicefiles.filter("*[@ID = '" + fp.text + "']")
		break if matches.size > 0
	}
	servicefilename = matches[0].xpath("./xmlns:FLocat/@xlink:href").text
	servicefileroot = servicefilename.gsub(/\..*$/, '')

	alto = Nokogiri::XML(File.open(path + "/" + ocrfilename))
	pagealtos[pageid] = alto

# get width and height from image - doesn't work for jp2
#	width, height = FastImage.size(path + "/" + servicefilename)

# get width and height from text element in ALTO 
# THIS SHOULD NOT BE NECESSARY
	processingStepSettings = alto.xpath("//xmlns:processingStepSettings")[0].text
	width = /^width:(\d*)/.match(processingStepSettings).captures[0].to_i
	height = /^height:(\d*)/.match(processingStepSettings).captures[0].to_i

	# gather toc
	otherContent = []
	pagearticles = articles.xpath("//xmlns:dmdSec[xmlns:mdWrap/xmlns:xmlData/mods:mods/mods:identifier=$pageid]", nil, {:pageid => pageid})

	pagearticles.each { |article| 
		articleid = article.xpath("@ID").text # e.g. artModsBib_8_5
		articlejson = id + "/annotation/list/" + articleid + ".json"
		articlemods = article.xpath("xmlns:mdWrap/xmlns:xmlData/mods:mods")
		articletitle = articlemods.xpath("mods:titleInfo/mods:title").text
		unless articlemods.xpath("mods:titleInfo/mods:subTitle").text.empty?
			articletitle = articletitle + ": " + articlemods.xpath("mods:titleInfo/mods:subTitle").text
		end
		articleclass = articlemods.xpath("mods:classification").text
		if articletitle.empty? 
			articletitle = "[" + articleclass + "]" 
		end 
		articleentry =     {
	        "@id" => articlejson,
	        "@type" => "sc:AnnotationList",
	        "label" => articletitle,
	        "within" => 
	        {
	            "@id" => id + "/annotation/layer/" + articleid + ".json",
	            "@type" => "sc:Layer",
	            "label" => "OCR Article Text"
	        }
	    }
	    otherContent.push(articleentry)

	    articlecanvases = []
    	# need list of textblocks from articles mets; then for each need xywh from page alto
    	logicalmap.xpath("xmlns:div/xmlns:div[@DMDID=$articleid]/xmlns:div/xmlns:fptr/xmlns:area[@COORDS]", nil, {:articleid => articleid}).each { |area| 
	    		coords = area.xpath("@COORDS").text
	    		x, y, xx, yy = coords.split(',')
	    		w = (xx.to_i - x.to_i).to_s
	    		h = (yy.to_i - y.to_i).to_s

	        articlecanvases.push(id + "/canvas/p" + pagenum + "#xywh=" + x + "," + y + "," + w + "," + h)
    	}

	    structure = {
	        "@id" => id + "/article/" + articleid,
	        "@type" =>"sc:Range",
	        "label" => articletitle,
	        "metadata" => 
	        [
	            {
	                "label" => "Article Category",
	                "value" => articleclass
	            }
	        ],
	        
	        "canvases" => articlecanvases,
	        "contentLayer" => [
	            {
	                "@id" => id + "/annotation/layer/" + articleid + ".json",
	                "@type" => "sc:Layer",
	                "label" => "OCR Article Text"
	            }
	        ]
        }
        structures.push(structure)
	} # article

	canvas = {
		"@context" => iiif_presentation_context,
		"@id" => id + "/canvas/p" + pagenum,
		"@type" => "sc:Canvas",
		"label" => "p. " + pagenum,
		"height" => height,
		"width" => width,

		"images" => [
			{
				"@context" => iiif_presentation_context,
				"@id" => id + "/annotation/p" + pagenum + "-image",
				"@type" => "oa:Annotation",
				"motivation" => "sc:painting",
				"resource" => {
					"@id" => id + "/res/page" + pagenum + ".jpg",
					"@type" => "dctypes:Image",
					"format" => "image/jpeg",
					"service" => {
						"@context" => iiif_image_context,
						"@id" => imageservice + "/" + servicefileroot,
						"profile" => iiif_profile
					},
					"height" => height,
					"width" => width
				},
				"on" => id + "/canvas/p" + pagenum
			}
		],
		"otherContent" => otherContent
	}
	canvases.push(canvas)
} # page

sequence["canvases"] = canvases
obj["sequences"] = [sequence]
obj["structures"] = structures
#puts JSON.pretty_generate(obj)
File.open("output/manifest.json", 'w') { |file| 
	file.write(JSON.pretty_generate(obj)) 
}