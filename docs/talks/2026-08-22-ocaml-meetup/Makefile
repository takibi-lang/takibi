TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf
HTML   := $(TARGET).html
THEME  := ../theme/takibi.css
IMAGES := ../../../img/takibi-icon-v3.png ../../../img/takibi-icon-back-v3.png

.PHONY: all show pdf clean

all: show

show:
	npx -y @marp-team/marp-cli@latest $(SRC)  --theme-set $(THEME) --allow-local-files --preview

pdf: $(SRC) $(THEME) $(IMAGES)
	npx -y @marp-team/marp-cli@latest $(SRC) --theme-set $(THEME) --allow-local-files --pdf

clean:
	rm -f $(PDF) $(HTML)
