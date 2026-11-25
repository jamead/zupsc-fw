-- Behavioral ADC model for simulation only (VHDL-2008).
-- Assumes LTC2376-20 normal mode: CHAIN=0, RDL/SDI=0, DGC disabled.
-- The output named sdi connects to the FPGA serial-data input;
-- it corresponds to the real ADC's SDO pin.
-- Reference: https://www.analog.com/media/en/technical-documentation/data-sheets/237620fb.pdf
--
-- Model/entity name retained for compatibility with the existing top_tb.
-- On CNV rising: sample a 100 Hz square-wave step using simulation time.
-- Default waveform: code 0 for 0..5 ms, code 471859 for 5..10 ms, repeat.
-- The high level is approximately 90% of positive full scale.
-- Transitions are reflected by the first CNV sample at/after each edge.
-- Change STEP_PERIOD, LOW_CODE and HIGH_CODE to adjust the stimulus.
-- After T_CONV: present the MSB. Capture it on the FIRST rising SCLK.
-- Each rising SCLK advances to the next bit after T_SDO; capture all
-- 20 bits on rising edges BEFORE that delay (ordinary FPGA clocked logic).
-- After bit 0 the model drives zero. Wait T_CONV + T_MSB before reading.
-- No reset is required. Initial output is zero; conversion output is X.
--
-- Simplifications: ideal quantization; no noise, DGC, daisy chain or
-- output-enable control. BUSY changes without pin propagation delay.
-- Only conversion overlap, 4 us cycle time and early reads are checked;
-- this is a functional model, not a complete datasheet timing checker.
--
-- Example testbench instantiation:
-- adc : entity work.ltc2376_sine_model
--   port map (cnv => adc_cnv, sclk => adc_sclk,
--             sdi => adc_sdi, busy => open);
-- Drive CNV every 4 us or slower. With default timing, start SCLK after
-- 3.005 us. A 25 MHz SCLK reads 20 bits in 800 ns.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ltc2376_step_model is
  generic (
    STEP_PERIOD  : time := 400 us; -- 100 Hz; low and high for 5 ms each
    LOW_CODE     : integer range -524288 to 524287 := 0;
    HIGH_CODE    : integer range -524288 to 524287 := 471859;
    T_CONV       : time := 3 us; -- datasheet maximum conversion time
    T_MSB        : time := 5 ns;
    T_SDO        : time := 8 ns
  );
  port (
    cnv  : in  std_logic;
    sclk : in  std_logic;
    sdi  : out std_logic := '0';
    busy : out std_logic := '0'
  );
end entity;

architecture behavioral of ltc2376_step_model is
  signal conversion_done : boolean := false;
begin
  assert STEP_PERIOD >= 2 ns and T_CONV > 0 ns and
         T_MSB >= 0 ns and T_SDO > 0 ns
    report "Invalid step period or timing generic" severity failure;

  model : process(cnv, sclk, conversion_done)
    variable converting : boolean := false;
    variable have_data  : boolean := false;
    variable pending    : std_logic_vector(19 downto 0) := (others => '0');
    variable word       : std_logic_vector(19 downto 0) := (others => '0');
    variable bit_index  : integer range 0 to 19 := 19;
    variable last_cnv   : time := 0 ns;
    variable seen_cnv   : boolean := false;
    variable code      : integer;
  begin
    if rising_edge(cnv) then
      if converting then
        assert false report "CNV during conversion: ignored" severity warning;
      else
        if seen_cnv then
          assert now - last_cnv >= 4 us
            report "LTC2376-20 CNV period is below 4 us" severity warning;
        end if;
        seen_cnv := true;
        last_cnv := now;
        -- Integer/time arithmetic only; no real-number sine calculation.
        -- Even half-periods are low, odd half-periods are high.
        if ((now / (STEP_PERIOD / 2)) mod 2) = 0 then
          code := LOW_CODE;
        else
          code := HIGH_CODE;
        end if;
        pending := std_logic_vector(to_signed(code, 20));
        converting := true;
        have_data := false;
        busy <= '1';
        sdi <= 'X';
        conversion_done <= not conversion_done after T_CONV;
      end if;
    elsif conversion_done'event then
      converting := false;
      have_data := true;
      word := pending;
      bit_index := 19;
      busy <= '0';
      sdi <= word(19) after T_MSB;
    elsif rising_edge(sclk) then
      if converting then
        assert false report "SCLK during conversion: ignored" severity warning;
      elsif have_data then
        if bit_index > 0 then
          bit_index := bit_index - 1;
          sdi <= word(bit_index) after T_SDO;
        else
          sdi <= '0' after T_SDO;
          have_data := false;
        end if;
      end if;
    end if;
  end process;
end architecture;
