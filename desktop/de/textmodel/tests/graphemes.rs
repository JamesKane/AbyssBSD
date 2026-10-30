//! The segmenter against the Unicode Character Database's own conformance
//! test, GraphemeBreakTest.txt (tests/data, © Unicode, Inc., Unicode License
//! v3; the same UCD gen-graphemes.py made the tables from). Every line is a
//! string with its boundaries marked: `÷` a break, `×` none.

use text_model::grapheme::clusters;

#[test]
fn every_case_in_the_unicode_conformance_test_segments_as_it_says() {
    let data = include_str!("data/GraphemeBreakTest.txt");
    let (mut n, mut wrong) = (0, vec![]);
    for line in data.lines() {
        let case = line.split('#').next().unwrap().trim();
        if case.is_empty() {
            continue;
        }
        // The expected clusters, as strings.
        let mut want: Vec<String> = vec![];
        let mut text = String::new();
        for tok in case.split_whitespace() {
            match tok {
                "÷" => want.push(String::new()),
                "×" => {}
                hex => {
                    let c = char::from_u32(u32::from_str_radix(hex, 16).unwrap()).unwrap();
                    want.last_mut().unwrap().push(c);
                    text.push(c);
                }
            }
        }
        want.pop(); // the final ÷ opens nothing
        let got: Vec<&str> = clusters(&text).collect();
        if got != want {
            wrong.push(format!("{case}: got {got:?}"));
        }
        n += 1;
    }
    assert!(n > 700, "only {n} cases");
    assert!(wrong.is_empty(), "{} of {n} wrong:\n{}", wrong.len(), wrong.join("\n"));
}
