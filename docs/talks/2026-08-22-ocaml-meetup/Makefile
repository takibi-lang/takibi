TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf
THEME  := ../theme/takibi.css
IMAGES := ../../../img/takibi-icon-v3.png ../../../img/takibi-icon-back-v3.png

.PHONY: all show watch clean

all: $(PDF)

$(PDF): $(SRC) $(THEME) $(IMAGES)
	npx @marp-team/marp-cli@latest $(SRC) --theme-set $(THEME) --allow-local-files --pdf

show: $(PDF)
	evince $(PDF)

watch:
	@echo "$(SRC)" >> .watch_list
	@cat .watch_list | entr make

clean:
	rm -f $(PDF) .watch_list
