TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf
HTML   := $(TARGET).html
THEME  := ../theme/takibi.css
IMAGES := ../../../img/takibi-icon-v3.png ../../../img/takibi-icon-back-v3.png
MEDIA  := demo.mp4
MARP   := npx -y @marp-team/marp-cli@latest $(SRC) --theme-set $(THEME) --allow-local-files --html

.PHONY: all show pdf clean

all: show

show:
	$(MARP) --preview

pdf: $(SRC) $(THEME) $(IMAGES) $(MEDIA)
	$(MARP) --pdf

clean:
	rm -f $(PDF) $(HTML)
