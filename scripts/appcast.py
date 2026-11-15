"""Writes the appcast with one more release: the previous appcast (if any) plus an item
for this version, newest first. An item already there for the same build is replaced.
scripts/release.sh signs the result with sign_update.

    appcast.py <previous appcast or ""> <output> <version> <build> <minimum macOS>
               <zip url> <release page> <length> <edSignature> <release notes .md>
"""
import email.utils, html, re, sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def s(tag):
    return f"{{{SPARKLE}}}{tag}"


def notes_html(markdown):
    """The two changelogs of RELEASE_NOTES.md (### headings and numbered items) as HTML."""
    parts = []
    for line in markdown.splitlines():
        if line.startswith("### "):
            if parts:
                parts.append("</ol>")
            parts += [f"<h3>{html.escape(line[4:], quote=False)}</h3>", "<ol>"]
        elif parts and re.match(r"\d+\. ", line):
            text = html.escape(line.split(". ", 1)[1], quote=False)
            parts.append("<li>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text) + "</li>")
    if parts:
        parts.append("</ol>")
    return "".join(parts)


def main(previous, output, version, build, minimum, url, page, length, signature, notes_path):
    if previous:
        tree = ET.parse(previous)  # drops comments, among them the old feed signature
        channel = tree.getroot().find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        tree = ET.ElementTree(root)
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Kamira"
    for item in channel.findall("item"):
        if item.findtext(s("version")) == build:
            channel.remove(item)

    notes = open(notes_path, encoding="utf-8").read()
    item = ET.Element("item")
    ET.SubElement(item, "title").text = re.search(r"^# (.+)$", notes, re.M)[1]
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, s("version")).text = build
    ET.SubElement(item, s("shortVersionString")).text = version
    ET.SubElement(item, s("minimumSystemVersion")).text = minimum
    ET.SubElement(item, "link").text = page
    ET.SubElement(item, "description").text = notes_html(notes)
    ET.SubElement(item, "enclosure", {"url": url, "length": length, "type": "application/octet-stream",
                                      s("edSignature"): signature})
    first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)

    ET.indent(tree)
    tree.write(output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 11:
        sys.exit(__doc__)
    main(*sys.argv[1:])
