# Figures in this catalog are generated. The `.dot` next to each `.svg` is the
# source; edit that and run `make -C docs/wont-compile`.
#
# Two rewrites are applied to Graphviz output on purpose:
#
# Font fallback. Graphviz bakes text positions computed with its own metrics
# and then names a single font. A reader whose system lacks it gets a
# substitute with different widths, and the text overflows the boxes it was
# laid out inside. The stack below keeps the metrics on the platforms a GitHub
# reader is likely to have.
#
# The background is handled in the `.dot` instead, by `bgcolor`: without it
# GitHub's dark theme shows dark text on its own dark page.
#
# Graphviz version skew changes generated coordinates, so regenerating an
# untouched figure can produce a large diff with no visual change. Review the
# rendered result, not the SVG text.

DOT ?= dot

DOTS := $(wildcard assets/*.dot)
SVGS := $(DOTS:.dot=.svg)

FONT_STACK := Helvetica, Arial, Liberation Sans, sans-serif

.PHONY: all clean
all: $(SVGS)

assets/%.svg: assets/%.dot
	$(DOT) -Tsvg $< -o $@.tmp
	sed -i -e 's/font-family="Helvetica,sans-Serif"/font-family="$(FONT_STACK)"/g' $@.tmp
	mv $@.tmp $@

clean:
	rm -f $(SVGS) assets/*.svg.tmp
