//! 양식 개체 values: 선택 상자 and 라디오 단추 chosen, 입력 상자 and 콤보 상자 text.
use super::*;
use rhwp::model::control::{Control, FormType};

fn kind(t: FormType) -> &'static str {
    match t {
        FormType::PushButton => "PushButton",
        FormType::CheckBox => "CheckBox",
        FormType::ComboBox => "ComboBox",
        FormType::RadioButton => "RadioButton",
        FormType::Edit => "Edit",
    }
}
/// Every 양식 개체 of the body and its table cells, with the paragraphs they are in.
fn each_form(
    doc: &rhwp::model::document::Document,
    mut visit: impl FnMut(FormRef, &rhwp::model::control::FormObject),
) {
    for (s, section) in doc.sections.iter().enumerate() {
        for (p, para) in section.paragraphs.iter().enumerate() {
            let at = |control, cell| FormRef {
                section: s as u32,
                paragraph: p as u32,
                control,
                cell,
            };
            for (c, control) in para.controls.iter().enumerate() {
                match control {
                    Control::Form(f) => visit(at(c as u32, None), f),
                    Control::Table(t) => {
                        for (i, cell) in t.cells.iter().enumerate() {
                            for (cp, cpara) in cell.paragraphs.iter().enumerate() {
                                for (fc, inner) in cpara.controls.iter().enumerate() {
                                    if let Control::Form(f) = inner {
                                        let place = CellTarget {
                                            control: c as u32,
                                            cell: i as u32,
                                            paragraph: cp as u32,
                                        };
                                        visit(at(fc as u32, Some(place)), f);
                                    }
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}
/// The paragraph a form stands in.
fn host(r: &FormRef) -> EditTarget {
    EditTarget {
        section: r.section,
        paragraph: r.paragraph,
        cell: r.cell.clone(),
        note: None,
        header_footer: None,
    }
}
/// Every form's value and text cleared, for checking that only they changed.
#[cfg(test)]
pub(super) fn without_values(paragraphs: &mut [rhwp::model::paragraph::Paragraph]) {
    for p in paragraphs {
        for c in &mut p.controls {
            match c {
                Control::Form(f) => {
                    (f.value, f.text) = (0, String::new());
                }
                Control::Table(t) => {
                    for cell in &mut t.cells {
                        without_values(&mut cell.paragraphs);
                    }
                }
                _ => {}
            }
        }
    }
}

impl EditSession {
    pub(super) fn form(&self, r: &FormRef) -> Result<&rhwp::model::control::FormObject, EditError> {
        match commands::get(self.core.document(), &host(r))?
            .controls
            .get(r.control as usize)
        {
            Some(Control::Form(f)) => Ok(f),
            _ => Err(EditError::UnsupportedTarget),
        }
    }
    /// The 양식 개체 under a page point (96 dpi, top-left origin).
    pub fn form_at(
        &self,
        revision: u64,
        page: u32,
        x: f64,
        y: f64,
    ) -> Result<Option<FormInfo>, EditError> {
        self.check_revision(revision)?;
        let v: serde_json::Value =
            serde_json::from_str(&self.core.get_form_object_at_native(page, x, y)?)
                .map_err(|_| EditError::RenderFailed)?;
        if v["found"] != true {
            return Ok(None);
        }
        let n = |k: &str| v[k].as_u64().unwrap_or(0) as u32;
        let r = if v["inCell"] == true {
            FormRef {
                section: n("sec"),
                paragraph: n("tablePara"),
                control: n("ci"),
                cell: Some(CellTarget {
                    control: n("tableCi"),
                    cell: n("cellIdx"),
                    paragraph: n("cellPara"),
                }),
            }
        } else {
            FormRef {
                section: n("sec"),
                paragraph: n("para"),
                control: n("ci"),
                cell: None,
            }
        };
        let f = self.form(&r)?;
        let items = if r.cell.is_none() {
            serde_json::from_str::<serde_json::Value>(&self.core.get_form_object_info_native(
                r.section as usize,
                r.paragraph as usize,
                r.control as usize,
            )?)
            .ok()
            .and_then(|i| {
                i["items"].as_array().map(|a| {
                    a.iter()
                        .filter_map(|s| s.as_str().map(String::from))
                        .collect()
                })
            })
            .unwrap_or_default()
        } else {
            Vec::new()
        };
        let b = &v["bbox"];
        let f64_of = |v: &serde_json::Value| v.as_f64().unwrap_or(0.0);
        Ok(Some(FormInfo {
            kind: kind(f.form_type).into(),
            name: f.name.clone(),
            caption: f.caption.clone(),
            value: f.value,
            text: f.text.clone(),
            enabled: f.enabled,
            items,
            rect: PageRect {
                page,
                x: f64_of(&b["x"]),
                y: f64_of(&b["y"]),
                width: f64_of(&b["w"]),
                height: f64_of(&b["h"]),
            },
            form: r,
        }))
    }
    pub(super) fn validate_form(
        &self,
        r: &FormRef,
        value: Option<i32>,
        text: Option<&str>,
    ) -> Result<(), EditError> {
        let f = self.form(r)?;
        let ok = f.enabled
            && match f.form_type {
                FormType::CheckBox | FormType::RadioButton => {
                    text.is_none() && value.is_some_and(|v| v == 0 || v == 1)
                }
                FormType::Edit | FormType::ComboBox => {
                    value.is_none() && text.is_some_and(|t| t.chars().count() <= 10_000)
                }
                FormType::PushButton => false,
            };
        if ok {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    /// Sets a form's value or text; a 라디오 단추 chosen leaves the others of its group.
    pub(super) fn set_form(
        &mut self,
        r: &FormRef,
        value: Option<i32>,
        text: Option<&str>,
    ) -> Result<(), EditError> {
        let f = self.form(r)?;
        let mut changes = vec![(r.clone(), value, text.map(String::from))];
        if f.form_type == FormType::RadioButton && value == Some(1) {
            let group = f
                .properties
                .get("RadioGroupName")
                .cloned()
                .unwrap_or_default();
            if !group.is_empty() {
                each_form(self.core.document(), |other, g| {
                    if other != *r
                        && g.form_type == FormType::RadioButton
                        && g.value != 0
                        && g.properties.get("RadioGroupName") == Some(&group)
                    {
                        changes.push((other, Some(0), None));
                    }
                });
            }
        }
        for (r, value, text) in changes {
            let mut json = serde_json::Map::new();
            if let Some(v) = value {
                json.insert("value".into(), v.into());
            }
            if let Some(t) = text {
                json.insert("text".into(), t.into());
            }
            let json = serde_json::Value::Object(json).to_string();
            let (s, p, c) = (r.section as usize, r.paragraph as usize, r.control as usize);
            match &r.cell {
                Some(cell) => self.core.set_form_value_in_cell_native(
                    s,
                    p,
                    cell.control as usize,
                    cell.cell as usize,
                    cell.paragraph as usize,
                    c,
                    &json,
                )?,
                None => self.core.set_form_value_native(s, p, c, &json)?,
            };
        }
        Ok(())
    }
}
