use scraper::{ElementRef, Html, Selector};

/// Convert HTML to clean markdown.
pub fn html_to_markdown(html: &str) -> String {
    let document = Html::parse_document(html);
    let mut out = String::with_capacity(html.len());
    walk(&document.root_element(), &mut out, 0);
    out.trim().to_string()
}

/// Extract plain text from HTML (strip script/style/etc).
pub fn html_to_text(html: &str) -> String {
    let document = Html::parse_document(html);
    let mut out = String::with_capacity(html.len());
    walk_text(&document.root_element(), &mut out);
    out.trim().to_string()
}

/// Best-effort page title from `<title>` or first `<h1>`.
pub fn extract_title(html: &str) -> String {
    let document = Html::parse_document(html);
    if let Ok(sel) = Selector::parse("title") {
        if let Some(t) = document.select(&sel).next() {
            let t = t.text().collect::<String>().trim().to_string();
            if !t.is_empty() {
                return t;
            }
        }
    }
    if let Ok(sel) = Selector::parse("h1") {
        if let Some(t) = document.select(&sel).next() {
            let t = t.text().collect::<String>().trim().to_string();
            if !t.is_empty() {
                return t;
            }
        }
    }
    String::new()
}

fn walk(elem: &ElementRef, out: &mut String, list_depth: usize) {
    for child in elem.children() {
        match child.value() {
            scraper::node::Node::Element(e) => {
                let tag = e.name();
                if matches!(
                    tag,
                    "script"
                        | "style"
                        | "noscript"
                        | "iframe"
                        | "object"
                        | "embed"
                        | "meta"
                        | "link"
                ) {
                    continue;
                }
                let child_elem = ElementRef::wrap(child).unwrap();
                match tag {
                    "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                        let level = tag.as_bytes()[1] - b'0';
                        out.push('\n');
                        for _ in 0..level {
                            out.push('#');
                        }
                        out.push(' ');
                        walk(&child_elem, out, list_depth);
                        out.push_str("\n\n");
                    }
                    "p" => {
                        walk(&child_elem, out, list_depth);
                        out.push_str("\n\n");
                    }
                    "br" => out.push('\n'),
                    "hr" => out.push_str("\n---\n\n"),
                    "a" => {
                        let href = e.attr("href").unwrap_or("");
                        let mut text = String::new();
                        walk(&child_elem, &mut text, list_depth);
                        let text = text.trim();
                        if !text.is_empty() {
                            out.push('[');
                            out.push_str(text);
                            out.push_str("](");
                            out.push_str(href);
                            out.push(')');
                        }
                    }
                    "strong" | "b" => {
                        out.push_str("**");
                        walk(&child_elem, out, list_depth);
                        out.push_str("**");
                    }
                    "em" | "i" => {
                        out.push('*');
                        walk(&child_elem, out, list_depth);
                        out.push('*');
                    }
                    "code" => {
                        out.push('`');
                        walk(&child_elem, out, list_depth);
                        out.push('`');
                    }
                    "pre" => {
                        out.push_str("\n```\n");
                        walk(&child_elem, out, list_depth);
                        out.push_str("\n```\n\n");
                    }
                    "blockquote" => {
                        out.push_str("\n> ");
                        walk(&child_elem, out, list_depth);
                        out.push('\n');
                    }
                    "ul" | "ol" => {
                        out.push('\n');
                        walk(&child_elem, out, list_depth + 1);
                        out.push('\n');
                    }
                    "li" => {
                        for _ in 0..list_depth {
                            out.push_str("  ");
                        }
                        out.push_str("- ");
                        walk(&child_elem, out, list_depth);
                        out.push('\n');
                    }
                    "img" => {
                        if let Some(alt) = e.attr("alt") {
                            let src = e.attr("src").unwrap_or("");
                            out.push_str("![");
                            out.push_str(alt);
                            out.push_str("](");
                            out.push_str(src);
                            out.push_str(")\n\n");
                        }
                    }
                    _ => walk(&child_elem, out, list_depth),
                }
            }
            scraper::node::Node::Text(t) => {
                let s = t.trim_matches(|c: char| c == '\n' || c == '\r');
                if !s.is_empty() {
                    out.push_str(s);
                }
            }
            _ => {}
        }
    }
}

fn walk_text(elem: &ElementRef, out: &mut String) {
    for child in elem.children() {
        match child.value() {
            scraper::node::Node::Element(e) => {
                if matches!(
                    e.name(),
                    "script" | "style" | "noscript" | "iframe" | "object" | "embed"
                ) {
                    continue;
                }
                let child_elem = ElementRef::wrap(child).unwrap();
                walk_text(&child_elem, out);
            }
            scraper::node::Node::Text(t) => out.push_str(t),
            _ => {}
        }
    }
}
