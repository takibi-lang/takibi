TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf
HTML   := $(TARGET).html
THEME  := ../theme/takibi.css
IMAGES := ../../../img/takibi-icon-v3.png ../../../img/takibi-icon-back-v3.png
# The figures are COPIES of docs/wont-compile/assets/, not references to them.
# A talk is a record of what was said on one day; a catalog figure is
# maintained and may be redrawn. Referencing the live one would silently
# rewrite this deck years after it was given.
FIGURES := assets/defect-0001.svg assets/defect-0002.svg \
	assets/defect-0004.svg assets/human-on-the-loop.svg
# assets/demo.mp4 and assets/demo.png are recorded separately and dropped in
# by hand, so they are deliberately NOT prerequisites: the deck has to build
# before the capture exists. The theme gives `section.video-slide video` a
# dark box with an ember border and a fixed height, so a missing capture
# renders as an empty frame of the right size rather than as a broken slide.
# demo.png is the poster, and it is the only thing a reader of the exported
# PDF will see, because a PDF cannot play video -- so check that slide by eye
# before exporting.
MARP   := npx -y @marp-team/marp-cli@latest $(SRC) --theme-set $(THEME) --allow-local-files --html

# `review` renders every slide to PNG. This is the only way a slide that
# overflows its box gets found: the source looks fine, and Marp does not
# complain -- the content simply runs under the footer or off the bottom.
# Three slides in this deck did that, and all three were caught here.
#
# Marp needs a real Chromium. The `chromium-browser` package on this image is
# a snap stub that cannot start inside a container ("requires the chromium
# snap to be installed"), so install one that works and point CHROME_PATH at
# it:
#
#     npx puppeteer browsers install chrome
#     make review CHROME_PATH=$HOME/.cache/puppeteer/chrome/linux-*/chrome-linux64/chrome
#
REVIEW_DIR := review

.PHONY: all show html pdf review clean

all: show

show:
	$(MARP) --preview

html: $(HTML)

$(HTML): $(SRC) $(THEME) $(IMAGES) $(FIGURES)
	$(MARP) -o $@

pdf: $(SRC) $(THEME) $(IMAGES) $(FIGURES)
	$(MARP) --pdf

review: $(SRC) $(THEME) $(IMAGES) $(FIGURES)
	mkdir -p $(REVIEW_DIR)
	$(MARP) --images png -o $(REVIEW_DIR)/slide.png

clean:
	rm -f $(PDF) $(HTML)
	rm -rf $(REVIEW_DIR)
