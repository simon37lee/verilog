## ---------------------------------------------------------------------------
## hdmi_top_xc7 제약 파일 템플릿
## PACKAGE_PIN 의 "XX" 는 사용하는 보드의 회로도/마스터 XDC 를 보고 채워야 한다.
## ---------------------------------------------------------------------------

## 100 MHz 시스템 클럭
set_property -dict { PACKAGE_PIN XX  IOSTANDARD LVCMOS33 } [get_ports clk_100m]
create_clock -period 10.000 -name sys_clk [get_ports clk_100m]

## 리셋 버튼 (active-high)
set_property -dict { PACKAGE_PIN XX  IOSTANDARD LVCMOS33 } [get_ports rst_btn]

## HDMI TX (IOSTANDARD 는 RTL 의 OBUFDS 에서 TMDS_33 으로 지정)
set_property PACKAGE_PIN XX [get_ports hdmi_clk_p]
set_property PACKAGE_PIN XX [get_ports {hdmi_d_p[0]}]
set_property PACKAGE_PIN XX [get_ports {hdmi_d_p[1]}]
set_property PACKAGE_PIN XX [get_ports {hdmi_d_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_clk_p hdmi_clk_n hdmi_d_p[*] hdmi_d_n[*]}]
