//! 차트 데이터 편집: a chart's 줄 names and 칸 (series) values.
use super::*;

impl EditSession {
    /// 차트 `chart`'s data (its number in the document).
    pub fn chart_data(&self, chart: u32) -> Result<ChartData, EditError> {
        let v: serde_json::Value =
            serde_json::from_str(&self.core.get_chart_data_by_index_native(chart as usize)?)
                .map_err(|_| EditError::RenderFailed)?;
        if v["ok"] != true {
            return Err(EditError::UnsupportedTarget);
        }
        let texts = |v: &serde_json::Value| -> Vec<String> {
            v.as_array()
                .map(|a| {
                    a.iter()
                        .map(|s| s.as_str().unwrap_or("").to_string())
                        .collect()
                })
                .unwrap_or_default()
        };
        Ok(ChartData {
            labels: texts(&v["labels"]),
            series: v["series"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|s| ChartSeries {
                            name: s["name"].as_str().unwrap_or("").into(),
                            values: texts(&s["values"]),
                        })
                        .collect()
                })
                .unwrap_or_default(),
        })
    }
    pub(super) fn validate_chart_data(
        &self,
        chart: u32,
        data: &ChartData,
    ) -> Result<(), EditError> {
        self.chart_data(chart)?;
        let rows = data.labels.len();
        let number = |t: &String| t.parse::<f64>().is_ok_and(f64::is_finite);
        if rows == 0
            || rows > 1_000
            || data.series.is_empty()
            || data.series.len() > 255
            || data
                .series
                .iter()
                .any(|s| s.values.len() != rows || !s.values.iter().all(number))
        {
            return Err(EditError::InvalidInput);
        }
        Ok(())
    }
    /// Writes `data` into chart `chart`; rhwp writes both its copies or neither.
    pub(super) fn set_chart_data(&mut self, chart: u32, data: &ChartData) -> Result<(), EditError> {
        let edits = serde_json::json!({
            "structure": true,
            "labels": data.labels,
            "series": data.series,
        });
        let reply: serde_json::Value = serde_json::from_str(
            &self
                .core
                .set_chart_data_by_index_native(chart as usize, &edits.to_string())?,
        )
        .map_err(|_| EditError::RenderFailed)?;
        if reply["ok"] != true {
            return Err(EditError::InvalidInput);
        }
        Ok(())
    }
}
